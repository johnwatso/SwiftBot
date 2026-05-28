# Archived Features and Legacy Code Reference

This directory serves as a preservation vault for deprecated or removed features of SwiftBot. The code is kept in an inactive, self-contained state in case developers need to reference historical implementations or restore components in the future.

---

## Overview of Archived Features

| File | Feature Name | Original Purpose | Reason for Removal / Archival | Date Archived |
| :--- | :--- | :--- | :--- | :--- |
| [`AutoBugFix.swift`](file:///Users/john/Documents/GitHub/SwiftBot/Archive/AutoBugFix.swift) | **Bug Auto-Fix** | Codex-driven automated codebase fixing triggered via Discord reactions. | Replaced by offline/agentic workflows. Gating repository writes via Discord reactions posed high security and stability risks. | May 26, 2026 |
| [`BugCommands.swift`](file:///Users/john/Documents/GitHub/SwiftBot/Archive/BugCommands.swift) | **In-Discord Bug Tracker** | Tracking and updating software bugs via `@swiftbot bug` replies and reaction status sync. | Replaced by dedicated issue trackers (e.g., GitHub Issues). Custom Discord threads were noisy, hard to query, and API-heavy. | May 26, 2026 |
| [`FeatureRequestCommand.swift`](file:///Users/john/Documents/GitHub/SwiftBot/Archive/FeatureRequestCommand.swift) | **In-Discord Feature Requests** | Slash command (`/featurerequest`) allowing users to request bot features and track status via reactions. | Consolidated to GitHub Discussions and dedicated feedback boards for better organization and milestone management. | May 26, 2026 |
| [`MultiProviderAI.swift`](file:///Users/john/Documents/GitHub/SwiftBot/Archive/MultiProviderAI.swift) | **Multi-Provider AI & DALL-E** | OpenAI, Ollama, provider racing (fastest engine wins), and image generation (`/image`). | Consolidated on native **Apple Intelligence** to eliminate API billing management, local host requirements, and REST latency. | May 27, 2026 |
| [`UnusedAuthProviders.swift`](file:///Users/john/Documents/GitHub/SwiftBot/Archive/UnusedAuthProviders.swift) | **Secondary WebUI Auth** | OAuth configurations and UI forms for Apple, Steam, and GitHub sign-ins. | Consolidated entirely on **Discord OAuth**, which is native to bot management and role-based permissions. | May 26, 2026 |
| [`PreferencesViewLegacy.swift`](file:///Users/john/Documents/GitHub/SwiftBot/Archive/PreferencesViewLegacy.swift) | **Legacy Preferences Window** | Original monolithic Preferences UI built from ultra-thin-material disclosure cards (`GeneralSettingsView` + `SettingsDisclosureCard`). | Superseded by the SwiftMiner-style `SettingsForm` + `Section` layout split across per-tab files. Still referenced model fields (`bugAutoFixEnabled`, `devFeaturesEnabled`) that were also removed. | May 28, 2026 |

---

## Detailed Feature References

### 1. Bug Auto-Fix (`AutoBugFix.swift`)

* **Functionality**:
  When a Discord user reacted with a specific emoji (default: `🤖`) to a tracked bug message, SwiftBot would:
  1. Clone the repository into a temporary, isolated workspace.
  2. Extract release version and build numbers (e.g., `version=1.8.19 build=181900`) from recent comments in the bug thread.
  3. Execute a local Codex command (e.g., `codex exec "$SWIFTBOT_BUG_PROMPT"`) to generate and apply a targeted bug fix.
  4. Post the generated git diff and summary to the Discord thread.
  5. Wait for approval: reacting with `🚀` would automatically commit and push the changes to GitHub to trigger the CI build; reacting with `🛑` aborted the session.
* **Why it was removed**:
      The feature was originally introduced during an early experimental phase of SwiftBot, when in-Discord automation and AI-assisted repository workflows were still being explored. Over time, the functionality saw little practical use, and SwiftBot evolved toward more mature and maintainable development workflows. During later security auditing, the system was also flagged for exposing unnecessary security risks due to its ability to execute local shell commands and perform repository actions through Discord interactions. Modern offline and agentic tooling now provides safer, isolated environments for automated debugging and code generation, making direct Discord-driven repository modification unnecessary.
* **Original Integration Points**:
  * `AppModel.swift` & `AppModel+Commands.swift` (session orchestration and reaction routing)
  * `BotSettings.swift` (configuration preferences for trigger emojis and templates)
  * `AdvancedPreferencesView.swift` (control panel UI)

---

### 2. In-Discord Bug Tracker (`BugCommands.swift`)

* **Functionality**:
  Allowed administrators to reply to any user message with `@swiftbot bug` (or call `/logabug`) to track an issue:
  1. Posted a bug card in a dedicated `#swiftbot-dev` text channel.
  2. Pinned the bug report card and created an active discussion thread.
  3. Seeded the report message with status emoji reactions (`🐞` New, `🔧 Working On`, `🟡 In Progress`, `⛔ Blocked`, `✅ Resolved`).
  4. Reacting to these emojis dynamically updated the report card's status line, logged status changes in the thread, and automatically unpinned the card once resolved.
  5. `/bugreport` generated server-wide bug metrics.
* **Why it was removed**:
  Maintaining an active, high-traffic bug tracking database inside Discord was fragile and rate-limited. Dedicated project boards (e.g., GitHub Issues) are far superior for historical searching, attachments, assignment, and integration with commits.
* **Original Integration Points**:
  * `AppModel+Commands.swift` (event tracking, parser and status reaction hooks)
  * `Services/CommandProcessor.swift` (slash command routing)
  * `Models/BotStateModels.swift` (`BugEntry` and `BugStatus` data structures)
  * `HelpEngine.swift` (help documentation)

---

### 3. In-Discord Feature Requests (`FeatureRequestCommand.swift`)

* **Functionality**:
  Users could run `/featurerequest <featureText> [reasonText]` in any server channel:
  1. Posted a clean feature card to the designated `#swiftbot-dev` channel and pinned it.
  2. Spawned a thread titled after the feature request.
  3. Seeded status reactions (`💡` New Request, `🧪 Needs Review`, `🗓️` Planned, `🚧` In Progress, `✅` Implemented, `❌` Declined).
  4. Reaction additions updated the main status line, posted notes to the thread, and unpinned implemented requests.
* **Why it was removed**:
  To reduce bot overhead and noise. Community feature requests are better served by community-driven platforms (like GitHub Discussions, Canny, or Trello) which allow broader voting, categorization, and sorting.
* **Original Integration Points**:
  * `AppModel+Commands.swift` (reaction handlers)
  * `Services/CommandProcessor.swift` (slash command handlers)
  * `AppModel+SlashCommandHelpers.swift` (helper parsing)

---

### 4. Multi-Provider AI & Image Generation (`MultiProviderAI.swift`)

* **Functionality**:
  SwiftBot previously supported parallel AI routing ("racing"):
  1. Instantiated multiple local or cloud providers simultaneously (Apple Intelligence, OpenAI Chat, and local Ollama hosts).
  2. Raced all active engines concurrently on incoming direct messages (DMs). Whichever returned a valid response first won, and the slower calls were cancelled.
  3. Included `/image` utilizing OpenAI DALL-E to generate and upload images, alongside rigid monthly rate limits and monthly hard caps tracked per user.
* **Why it was removed**:
  To focus exclusively on a robust, native **Apple Intelligence** integration. This consolidation removes huge swaths of HTTP client boilerplate, avoids third-party API key billing management (OpenAI), removes the need to maintain local Ollama host connections on user setups, and guarantees absolute data privacy and ultra-low latency.
* **Original Integration Points**:
  * `SwiftBotApp/Services/DiscordAIService.swift` (engine structs and concurrency racing logic)
  * `SwiftBotApp/Models/AIModels.swift` & `BotSettings.swift` (provider settings and models)
  * `SwiftBotApp/AIBotsView.swift` (engine selection and host configuration forms)
  * `SwiftBotApp/AppModel+Commands.swift` (image generation limits and DALL-E pipeline)

---

### 5. Secondary OAuth UI Auth (`UnusedAuthProviders.swift`)

* **Functionality**:
  Configured OAuth login forms for Apple, Steam, and GitHub to log into the Admin Web UI.
* **Why it was removed**:
  To simplify login flows. Since SwiftBot is a Discord bot manager, access is strictly governed by Discord server membership and server role hierarchies. Discord OAuth was retained as the single source of truth for Web UI authorization, making secondary login screens redundant.
* **Original Integration Points**:
  * `WebUIPreferencesView.swift` (OAuth configuration card sections)
  * `Models/BotSettings.swift` (credentials storage)

---

### 6. Legacy Preferences Window (`PreferencesViewLegacy.swift`)

* **Functionality**:
  The original SwiftBot Preferences UI: a single monolithic window built from a `GeneralSettingsView` host plus a stack of `SettingsDisclosureCard` blocks rendered against an `ultraThinMaterial` background with `RoundedRectangle` borders. Each card (General, SwiftMesh, Web UI, Recordings, Advanced, Bug Auto-Fix, etc.) was expanded/collapsed via `@AppStorage`-persisted disclosure state and used a custom `sectionTitle` / `settingsToggleRow` / `settingsSubsectionTitle` micro-DSL declared inline at the bottom of the file.
* **Why it was removed**:
  Superseded by the SwiftMiner-style preferences layout introduced in commit **`48aa357` — "Refactor preferences UI; dev features DEBUG-only"**. The new layout splits each tab into its own file (`GeneralPreferencesView`, `MeshPreferencesView`, `WebUIPreferencesView`, `UpdatesPreferencesView`, `AdvancedPreferencesView`, `SwiftMinerPreferencesView`, `DiscordPreferencesView`) hosted by `PreferencesView.swift`, and standardises on the native macOS grouped `Form` look via the `SettingsForm` / `Section` primitives in `CommonUI.swift`. The legacy file also still referenced model fields that the same refactor removed from `BotSettings` (`bugAutoFixEnabled`, `devFeaturesEnabled`), so it could no longer compile.
* **Original Integration Points**:
  * `SwiftBotApp.swift` / `AppDelegate` (preferences scene hosting the legacy window — pre-refactor)
  * `BotSettings.swift` (`bugAutoFixEnabled`, `devFeaturesEnabled`, and other now-removed fields)
  * `AppUpdater` (update-channel UI rendered inside the legacy General card)
  * `CommonUI.swift` (older glass-card modifiers, now replaced by `SettingsForm` + `Section`)

---

> [!NOTE]
> If you need to restore any of these features, refer to the files in this folder. When restoring, ensure that the corresponding views, settings models, and command processors are updated to hook back into the main app lifecycle.
