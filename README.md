<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/app-icon-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/app-icon-light.png">
    <img src="assets/readme/app-icon-light.png" width="120" alt="SwiftBot icon">
  </picture>
</p>

<h1 align="center">SwiftBot - Native macOS Discord Bot Dashboard</h1>

<p align="center">
  Run, configure, monitor, and automate a Discord bot from a native macOS app.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026-blue" alt="Platform badge">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift badge">
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-black" alt="Architecture badge">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License badge">
  <img src="https://img.shields.io/badge/status-active%20development-orange" alt="Status badge">
</p>

**SwiftBot** is a native macOS app for running and managing a Discord bot without living in config files or terminal sessions. Built with Swift and SwiftUI, it provides a single dashboard for bot setup, automation, commands, diagnostics, AI providers, update monitoring, and SwiftMesh failover.

It can run as a single local bot or as part of a SwiftMesh setup where a primary node handles Discord output and standby nodes can take over.

## Preview

### App Preview

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/ui-preview-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/ui-preview-light.png">
    <img src="assets/readme/ui-preview-light.png" alt="SwiftBot dashboard preview">
  </picture>
</p>

### Web UI Preview

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/webui-preview-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/webui-preview-light.png">
    <img src="assets/readme/webui-preview-light.png" alt="SwiftBot web UI preview">
  </picture>
</p>

## Features

- Native Discord bot runtime with token validation and invite link generation
- Slash commands, command logging, and channel configuration
- Automation rules for voice events, messages, and member joins
- Patchy update notifications (AMD, NVIDIA, Intel, Steam)
- WikiBridge-backed knowledge commands
- AI reply flows via Apple Intelligence, Ollama, or OpenAI
- Diagnostics for gateway, REST, latency, permissions, intents, rate limits
- SwiftMesh primary/standby failover
- Keychain-stored tokens, cached Discord metadata, Sparkle auto-updates

## Setup

- ➡️ **[Install Guide](docs/help/INSTALL.md)** — download, install, requirements, updates.
- ➡️ **[Bot Setup Guide](docs/help/BOT_SETUP.md)** — Discord application, token, intents, OAuth, troubleshooting.
- ➡️ **[Web UI Setup Guide](docs/help/WEB_UI_SETUP.md)** — local-only vs public access (Cloudflare Tunnel, reverse proxy).

More walkthroughs live in [docs/help/](docs/help/).

## Application Areas

| Area | Purpose |
| --- | --- |
| Overview | Bot status, activity, and runtime state |
| Voice / Actions | Rule builder for voice, message, and member-join automation |
| Commands / Command Log | Command controls and recent command activity |
| WikiBridge | External knowledge sources and dynamic command setup |
| Patchy | Driver, platform, and Steam update monitoring |
| AI Bots | Apple Intelligence, Ollama, and OpenAI configuration |
| Diagnostics | Gateway, REST, permissions, intents, and health checks |
| SwiftMesh | Primary, standby, failover, and mesh diagnostics |
| Logs / Settings | Token management, runtime logs, updates, and app configuration |

## Storage

App data lives in `~/Library/Application Support/SwiftBot/` (`settings.json`, `rules.json`, `discord-cache.json`, `mesh-cursors.json`). Bot tokens are stored in macOS Keychain.

## Project Layout

```text
SwiftBotApp/             macOS app, SwiftUI interface, Discord runtime, diagnostics, SwiftMesh
Sources/UpdateEngine/    reusable update-checking engine used by Patchy
Tools/SparklePublisher/  Sparkle publishing helper
Tests/SwiftBotTests/     application test suite
docs/                    GitHub Pages site, release notes, Sparkle appcasts
notes/                   internal planning, design, and review docs
```

## Notes

> [!CAUTION]
> SwiftBot depends on Discord APIs, gateway behavior, and bot permissions, which can change over time. Keep the app updated and review Discord's developer policies.

> [!WARNING]
> Bot permissions and privileged gateway intents must be configured correctly. Missing intents or channel permissions can prevent commands, member events, message triggers, or notifications from working.

> [!NOTE]
> SwiftBot is under active development — features, UI, and configuration may change between releases.

## Issues

Please raise a GitHub issue if something breaks. Include the SwiftBot version, macOS version, affected area, and any relevant diagnostics or log output.

## Related Docs

- [Help & Setup Guides](docs/help/)
- [Architecture](ARCHITECTURE.md)
- [AI Guide](AI_GUIDE.md)

## Releases

- [GitHub Releases](https://github.com/johnwatso/SwiftBot/releases)
- [Stable appcast](https://johnwatso.github.io/SwiftBot/appcast.xml) · [Beta appcast](https://johnwatso.github.io/SwiftBot/beta/appcast.xml)

## License

MIT
