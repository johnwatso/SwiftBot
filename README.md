<p align="center">
  <img src="App Images/app-icon.png" width="120" alt="SwiftBot Icon">
</p>

<h1 align="center">SwiftBot</h1>

<p align="center">
  Native macOS Discord bot dashboard built with SwiftUI
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026-blue">
  <img src="https://img.shields.io/badge/swift-5.9-orange">
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-black">
  <img src="https://img.shields.io/badge/license-GPLv3-blue">
  <img src="https://img.shields.io/badge/status-active%20development-orange">
</p>

## Development Status

SwiftBot is under active development.

Features, UI, and configuration may change frequently as the app evolves. Occasional breakage between releases is expected while core systems are refined and stabilized.

## Preview

<p align="center">
  <img src="App Images/ui-preview.png" alt="SwiftBot Dashboard Preview">
</p>

## Install

SwiftBot installs are distributed through [GitHub Releases](https://github.com/johnwatso/SwiftBot/releases).

1. Download the latest release from [GitHub Releases](https://github.com/johnwatso/SwiftBot/releases).
2. Open the `.dmg` or `.zip`.
3. Move `SwiftBot.app` to `/Applications`.
4. Launch SwiftBot and complete onboarding.

Future updates are handled in-app through Sparkle auto-updates.

## Discord Bot Setup

SwiftBot requires a Discord application with a bot user.

1. Go to the Discord Developer Portal  
   https://discord.com/developers/applications

2. Click **New Application**

3. Give the application a name (for example `SwiftBot`)

4. Open the **Bot** section

5. Click **Add Bot**

6. Enable the required **Privileged Gateway Intents**:

   - Server Members Intent
   - Message Content Intent

7. Copy the **Bot Token**

You will paste this token into SwiftBot during the onboarding process.

After the token is validated, SwiftBot will automatically generate the correct **server invite link** for your bot.

Invite the bot to your server using that generated link, then complete onboarding.

## Features

### Bot Control

- Native Discord Gateway and REST runtime
- Guided onboarding with token validation and invite link generation
- Prefix and slash command support
- Command logging and channel configuration tools

### Automation

- Voice event automation rules
- Member join welcome flows
- Message trigger rules
- Per-guild notification templates and voice activity logging

### AI Integration

- Apple Intelligence support
- Ollama local model support
- OpenAI integration
- Configurable AI routing for supported reply flows

### Knowledge & Data

- WikiBridge source management
- Dynamic wiki-backed commands
- Game metadata and reference query surfaces

### Monitoring

- Patchy monitoring for AMD, NVIDIA, Intel, and Steam updates
- Scheduled checks, delivery targets, and test sends

### Reliability

- SwiftMesh primary and fail-over clustering
- Conversation and wiki-cache replication
- Persistent local settings and cached Discord metadata

### Diagnostics

- Gateway, REST, latency, rate-limit, permissions, and intents visibility
- On-demand connection testing and runtime health checks

## Application Areas

| Area | Purpose |
| --- | --- |
| Overview | High-level bot status, activity, and summary information |
| Voice / Actions | Automation rule builder for voice, message, and member-join flows |
| Commands / Command Log | Command controls and recent command activity |
| WikiBridge | External knowledge source management and dynamic command configuration |
| Patchy | Driver and platform update monitoring |
| AI Bots | Apple Intelligence, Ollama, and OpenAI configuration |
| Diagnostics | Connection health, API checks, and remediation visibility |
| SwiftMesh | Cluster topology, fail-over state, and mesh diagnostics |
| Logs / Settings | Token management, runtime logs, and app configuration |

## Commands

SwiftBot supports both prefix commands and slash commands. The prefix is configurable in Settings, and WikiBridge can add commands from enabled sources.

### General

- `help`
- `ping`
- `roll`
- `8ball`
- `poll`
- `userinfo`

### Server / Admin

- `setchannel`
- `ignorechannel`
- `notifystatus`
- `debug`
- `bugreport`
- `weekly`

### AI / Media

- `image`
- `imagine`

### Knowledge

- `meta`
- `wiki`

### Cluster - SwiftMesh

- `cluster`

Additional slash commands include `compare`, `logabug`, and `featurerequest`.

## Storage

SwiftBot stores application data in `~/Library/Application Support/SwiftBot/`.

Common files include:

- `settings.json`
- `rules.json`
- `discord-cache.json`
- `mesh-cursors.json`

Bot tokens are stored securely in macOS Keychain.

## Repository Layout

- `SwiftBotApp/` - main macOS application, SwiftUI interface, Discord runtime, diagnostics, and SwiftMesh
- `Sources/UpdateEngine/` - reusable update-checking engine used by Patchy
- `Tools/SparklePublisher/` - Sparkle publishing helper
- `Tests/SwiftBotTests/` - application test suite
- `docs/` - release notes, appcasts, and planning/reference docs

## Documentation

- [Architecture](ARCHITECTURE.md)
- [AI Guide](AI_GUIDE.md)
- [Changelog](CHANGELOG.md)
- [Risk Matrix](RISK_MATRIX.md)
- [Feature Plan](docs/FEATURE_PLAN_PHASE1.txt)

## Releases

- [GitHub Releases](https://github.com/johnwatso/SwiftBot/releases) for installers and release notes
- [Stable appcast](https://johnwatso.github.io/SwiftBot/appcast.xml)
- [Beta appcast](https://johnwatso.github.io/SwiftBot/beta/appcast.xml)

Sparkle uses the published appcasts to deliver automatic updates after installation.

## Contributing

- Create a focused branch for each change.
- Keep updates small, clear, and easy to review.
- Include test notes and screenshots for behavior or UI changes.
- Open a pull request with a concise summary of what changed.
