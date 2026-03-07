```{=html}
<p align="center">
```
`<img src="App Images/app-icon.png" width="120" alt="SwiftBot Icon">`{=html}
```{=html}
</p>
```
```{=html}
<h1 align="center">
```
SwiftBot
```{=html}
</h1>
```
```{=html}
<p align="center">
```
Native macOS Discord bot dashboard built with SwiftUI
```{=html}
</p>
```
```{=html}
<p align="center">
```
macOS 26 • Swift 5.9 • Apple Silicon • GPLv3
```{=html}
</p>
```

------------------------------------------------------------------------

## Development Status

SwiftBot is under active development.

Features, UI, and configuration may change frequently while the project
evolves.\
Expect rapid iteration and occasional breakage between releases while
core systems are refined.

Feedback, bug reports, and suggestions are welcome.

------------------------------------------------------------------------

## Preview

```{=html}
<p align="center">
```
`<img src="App Images/ui-preview.png" alt="SwiftBot Dashboard Preview">`{=html}
```{=html}
</p>
```
```{=html}
<p align="center">
```
`<em>`{=html}SwiftBot dashboard running on macOS`</em>`{=html}
```{=html}
</p>
```

------------------------------------------------------------------------

# Install

Download the latest build from GitHub Releases:

https://github.com/johnwatso/SwiftBot/releases

1.  Download the latest release
2.  Open the `.dmg` or `.zip`
3.  Move **SwiftBot.app** to Applications
4.  Launch SwiftBot and complete onboarding

SwiftBot uses Sparkle for automatic updates, so future releases will
install automatically.

------------------------------------------------------------------------

# Features

SwiftBot combines several bot management tools into one native macOS
dashboard.

## Bot Control

-   Native Discord Gateway + REST runtime
-   Prefix and slash command support
-   Command logging
-   Invite link generation
-   Guided onboarding flow

## Automation

-   Voice event automation
-   Member join workflows
-   Message trigger rules
-   Notification templates

## AI Integration

-   Apple Intelligence routing
-   Ollama local model support
-   OpenAI integration
-   AI command surfaces

## Knowledge & Data

-   WikiBridge dynamic commands
-   External wiki sources
-   Game metadata queries

## Monitoring

Patchy monitoring for:

-   AMD driver releases
-   NVIDIA driver releases
-   Intel driver releases
-   Steam platform updates

## Reliability

-   SwiftMesh clustering
-   Primary / worker failover
-   Mesh state synchronization
-   Conversation and wiki cache replication

## Diagnostics

-   Gateway connection health
-   REST API status
-   Rate limit monitoring
-   Permission validation
-   Latency testing

------------------------------------------------------------------------

# Application Areas

SwiftBot is organized into several main sections.

  Area              Purpose
  ----------------- ----------------------------------------------------
  Overview          Bot status and activity
  Voice / Actions   Automation rule builder
  Commands / Log    Command configuration and activity
  WikiBridge        External knowledge source management
  Patchy            Driver and platform update monitoring
  AI Bots           Apple Intelligence / Ollama / OpenAI configuration
  Diagnostics       Gateway health and connectivity tests
  SwiftMesh         Cluster topology and failover monitoring
  Logs / Settings   Token management and runtime logs

------------------------------------------------------------------------

# Commands

SwiftBot supports both prefix commands and slash commands.

The prefix is configurable in Settings.

WikiBridge can dynamically add commands from enabled sources.

## General

    help
    ping
    roll
    8ball
    poll
    userinfo

## Server / Admin

    setchannel
    ignorechannel
    notifystatus
    debug
    bugreport
    weekly

## AI / Media

    image
    imagine

## Knowledge

    meta
    wiki

## Cluster

    cluster

Additional slash commands include:

    compare
    logabug
    featurerequest

------------------------------------------------------------------------

# Storage

SwiftBot stores local data in:

    ~/Library/Application Support/SwiftBot/

Files include:

    settings.json
    rules.json
    discord-cache.json
    mesh-cursors.json

Bot tokens are stored securely in macOS Keychain.

------------------------------------------------------------------------

# Repository Layout

    SwiftBotApp/
      main macOS application
      UI + runtime + clustering

    Sources/UpdateEngine/
      Patchy monitoring engine

    Tools/SparklePublisher/
      Sparkle publishing helper

    Tests/SwiftBotTests/
      app test suite

    docs/
      planning and architecture docs

------------------------------------------------------------------------

# Documentation

-   ARCHITECTURE.md
-   AI_GUIDE.md
-   CHANGELOG.md
-   RISK_MATRIX.md
-   docs/FEATURE_PLAN_PHASE1.txt

------------------------------------------------------------------------

# Releases

Stable appcast

    https://johnwatso.github.io/SwiftBot/appcast.xml

Beta appcast

    https://johnwatso.github.io/SwiftBot/beta/appcast.xml

Release helper

    scripts/publish_sparkle_release.sh

------------------------------------------------------------------------

# Contributing

1.  Create a focused feature branch
2.  Keep commits small and clearly scoped
3.  Include screenshots for UI changes
4.  Include testing notes for behaviour changes
