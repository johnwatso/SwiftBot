# SwiftBot

![platform](https://img.shields.io/badge/platform-macOS%2026-blue)
![swift](https://img.shields.io/badge/swift-5.9-orange)
![architecture](https://img.shields.io/badge/arch-Apple%20Silicon-black)
![license](https://img.shields.io/badge/license-GPLv3-blue)
![status](https://img.shields.io/badge/status-active-brightgreen)

SwiftBot is a **native macOS Discord bot dashboard** built with **SwiftUI and Swift Concurrency**.

It provides a fully local control panel for running and managing Discord bots with features like automations, AI routing, diagnostics, patch monitoring, and clustered fail-over — all from a desktop app.

---

# Preview

<img src="SwiftBotApp/Resources/AppIcon.png" alt="SwiftBot App Icon" width="96" />

![SwiftBot UI](App%20Images/Bot%20UI.png)

---

# Features

SwiftBot combines multiple bot management tools into a single native macOS application.

### Bot Control
- Native Discord Gateway + REST runtime
- Prefix and slash command support
- Command logging and diagnostics
- Invite link generation and onboarding

### Automations
- Voice event automation
- Member join workflows
- Message trigger rules
- Custom notification templates

### AI Integration
- Apple Intelligence routing
- Ollama local model support
- OpenAI integration
- AI command surfaces

### Knowledge + Data
- WikiBridge dynamic commands
- External wiki sources
- Game metadata queries

### Monitoring
- Patchy driver monitoring
  - AMD
  - NVIDIA
  - Intel
  - Steam updates

### Reliability
- SwiftMesh clustering
- Primary + worker failover
- Mesh state synchronization
- Conversation and wiki cache replication

### Diagnostics
- Gateway connection health
- REST API status
- Rate-limit checks
- Permission validation
- Latency testing

---

# Current Status

### Implemented

- Guided onboarding with token validation
- Bot identity lookup
- Invite link generation
- Clear-token reset flow
- Discord Gateway + REST runtime
- Prefix + slash command system
- Voice activity logging
- Patchy update monitoring
- WikiBridge source management
- AI routing across Apple Intelligence / Ollama / OpenAI
- Diagnostics dashboard
- SwiftMesh clustering
- Sparkle update feeds

### Planned / In Progress

- SwiftMesh worker mode return
- Menu bar connection indicator
- Launch at Login
- Reconnect and backoff tuning UI
- Dynamic beta Dock icon
- Analytics mode
- Context-aware AI replies
- Local wiki knowledge cache

---

# App Areas

SwiftBot is organized into several major views.

| Area | Purpose |
|-----|-----|
| Overview | Bot status, metrics, and high-level activity |
| Voice / Actions | Automation rule builder |
| Commands / Log | Command surfaces and command history |
| WikiBridge | External knowledge source configuration |
| Patchy | Driver and platform release monitoring |
| AI Bots | Apple Intelligence / Ollama / OpenAI configuration |
| Diagnostics | Gateway health and connectivity checks |
| SwiftMesh | Cluster topology and failover status |
| Logs / Settings | Token management and runtime logs |

---

# Getting Started

## Requirements

- Recent **Xcode** with macOS 26 SDK
- A **Discord application** with a bot user
- Bot token with required intents

---

## Setup

1. Create a Discord app in the Developer Portal  
   https://discord.com/developers/applications

2. Add a **Bot User**.

3. Enable required **Gateway Intents**.

4. Open the project in Xcode

