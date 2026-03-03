# SwiftBot (SwiftUI macOS)

A native macOS Discord bot dashboard app written in SwiftUI and Swift Concurrency (`async/await` + actors). It connects directly to Discord Gateway and REST APIs with no Electron or Node.js runtime.

## Documentation

- **[CHANGELOG.md](CHANGELOG.md)** - All changes and fixes made to the project
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Technical architecture and design patterns
- **[AI_GUIDE.md](AI_GUIDE.md)** - Quick reference for AI assistants and developers

## Preview

### App Icon

<img src="SwiftBotApp/Resources/AppIcon.png" alt="SwiftBot App Icon" width="96" />

### App UI

![SwiftBot UI](App%20Images/Bot%20UI.png)

## Features

- Native SwiftUI desktop UI pages:
  - Overview
  - Patchy
  - Actions
  - Commands
  - Logs
  - Settings
  - AI Bots
  - Status
- Discord Gateway (`wss://gateway.discord.gg/?v=10&encoding=json`) connection
  - Handles hello, heartbeat, identify, reconnect, and invalid session flow
- Discord REST sending via `https://discord.com/api/v10`
- Actions rule engine:
  - Triggers: user joins/leaves/moves voice, message contains
  - Conditions: server, voice channel, username contains, minimum duration
  - Actions: send message, add log entry, set status
- Per-guild notification channel configuration and ignore/monitor lists
- Voice presence tracking (join/move/leave) with session timing and recent activity panels
- Patchy monitoring dashboard:
  - SourceTarget-based configuration grouped by source (AMD, NVIDIA, Intel Arc, Steam)
  - Per-target server/channel/role mention routing
  - Hourly runtime scheduler with manual debug check support
  - Discord embed-first delivery using UpdateEngine `embedJSON` with text fallback only when embed JSON is missing/invalid
  - Steam App ID name resolution and local name cache
- Offline Discord metadata cache:
  - Caches servers, channels, roles, and known users locally
  - Patchy target editing still works while bot is offline
- Command system with prefix and commands:
  - `!help`
  - `!ping`
  - `!roll NdS`
  - `!8ball <question>`
  - `!poll "Question" "Option 1" "Option 2"`
  - `!userinfo [@user]`
  - `!finals <question>`
  - `!setchannel #channel`
  - `!ignorechannel #channel|list|remove #channel`
  - `!notifystatus`
- Logs view with auto-scroll, clear, and copy functionality
- Status view showing gateway stats and voice presence information
- On-device Apple Intelligence replies:
  - Optional smart DM and channel replies (Beta) when enabled in Settings
  - Smart replies on @mentions in guild channels using on-device Apple Intelligence (Beta)
- Persistent settings, rules, and Discord metadata saved in Application Support JSON

## Roadmap / Want To Add

- ✅ ~~General server notifications (join/leave events, voice activity, session duration)~~ - **Working!**
- Voice session tracking for analytics and summaries
- AI patch note summaries using a local LLM
- Notification channel auto-cleanup (e.g. clear every 24 hours)
- Weekly server activity summaries based on logged usage
- Game/wiki data lookup commands (e.g. weapon stats from a game wiki)
- Improved rule builder UI with drag-and-drop automation
- Plugin system to extend features modularly
- Web dashboard / remote access with Discord SSO
- Improved macOS UI design (modern SwiftUI / glass-style interface)

## Commands

- `!help`
- `!ping`
- `!roll NdS`
- `!8ball <question>`
- `!poll "Question" "Option 1" "Option 2"`
- `!userinfo [@user]`
- `!finals <question>`
- `!setchannel #channel`
- `!ignorechannel #channel|list|remove #channel`
- `!notifystatus`

Unknown commands return:

`❓ I don't know that command! Type !help to see all available commands.`

## On-Device AI Replies (Beta)

- Uses Apple on-device Foundation Models when available.
- Controlled via the Apple Intelligence settings toggle.
- Disabled by default.
- Implementation inspiration/reference: [Apple-Intelligence-API by gouwsxander](https://github.com/gouwsxander/Apple-Intelligence-API).

## Known Issues

- `AI Bots` provider icons (Apple Intelligence / Ollama) may render inconsistently or fall back incorrectly on some builds.
- Current status: tracking as a known UI issue; functionality is unaffected.

## High Availability / Cluster Options

SwiftBot includes cluster operating modes for routing workload, but it is not full automatic HA/failover.

- `Standalone`: one node runs Discord and local jobs.
- `Leader`: owns Discord connection and can offload AI/wiki jobs to a worker over HTTP; falls back to local handling if worker is unavailable.
- `Worker`: runs job services only and does not connect to Discord.

Current limitations:

- No automatic leader election.
- No active-active Discord leaders.
- No replicated cross-node state store.

## UpdateEngine Integration

`UpdateEngine` is a standalone Swift package in `Sources/UpdateEngine` that provides reusable update-source infrastructure for driver/news feeds.

- Current state: integrated into SwiftBot runtime for Patchy source monitoring and Discord delivery.
- Runtime scheduling, target grouping, and Discord routing remain owned by `SwiftBotApp`.
- Built-in sources today: NVIDIA, AMD, Intel Arc, and Steam.
- Design intent: keep source fetching/parsing separate from runtime delivery and Discord command/event handling.

## Build in Xcode

1. Open this folder in Xcode 15+.
2. Open `SwiftBot.xcodeproj`.
3. Select the `SwiftBot` scheme.
4. Build and run the macOS app target.

## Build Standalone `.app`

Build and archive the app directly from Xcode using your normal signing configuration.

## Software Updates

SwiftBot is now wired for Sparkle-based self-updates in Xcode.

Recommended release flow:

1. Build and sign the app in Xcode using your normal Developer ID setup.
2. Export a release archive and upload the signed `.zip` or `.dmg` to GitHub Releases.
3. Host the Sparkle appcast XML at a stable URL such as GitHub Pages.
4. Set these app target build settings in Xcode:
   - `SUFeedURL`
   - `SUPublicEDKey`

Once those are configured, SwiftBot will expose `Check for Updates...` in the app menu and Settings.

### Publishing A Release

The repo is set up so:

- GitHub Releases hosts the signed update archive
- GitHub Pages hosts the Sparkle appcast at [https://johnwatso.github.io/SwiftBot/appcast.xml](https://johnwatso.github.io/SwiftBot/appcast.xml)
- [scripts/publish_sparkle_release.sh](/Users/max/Developer/SwiftBot/scripts/publish_sparkle_release.sh) updates `docs/appcast.xml` for the latest release

Suggested release steps:

1. Archive and sign SwiftBot in Xcode.
2. Export a signed `.app` from Xcode, or export a signed `.zip`.
3. Create release notes HTML in `docs/release-notes/<version>.html` if you want Sparkle notes.
4. Run:

```bash
scripts/publish_sparkle_release.sh <version> <exported-app-or-zip> [release-notes-html]
```

5. If `gh` is installed and authenticated, the script will create/update GitHub Release `v<version>` and upload the asset automatically.
6. Commit and push the updated `docs/appcast.xml` and any release notes files.
7. GitHub Pages will deploy automatically from `docs/` via `.github/workflows/pages.yml`.

Notes:

- The helper script expects Sparkle's `generate_appcast` tool to be available after Xcode resolves the Sparkle package.
- If needed, set `SPARKLE_GENERATE_APPCAST` to the full path of `generate_appcast`.
- If your Sparkle setup uses an explicit private key file for appcast generation, set `SPARKLE_PRIVATE_KEY_PATH`.
- If you pass a `.app`, the script creates `release-artifacts/SwiftBot-<version>.zip` automatically using `ditto`.
