# SwiftBot

A native macOS Discord bot dashboard built with SwiftUI and Swift Concurrency.

## Features

- Native macOS app (no Electron/Node runtime)
- Discord Gateway + REST integration
- Actions and automation rules
- Patchy monitoring (AMD, NVIDIA, Intel Arc, Steam)
- Built-in bot command system
- Logs, status, and diagnostics views
- Optional on-device AI replies (Apple Intelligence)
- Persistent local settings and metadata cache

## Preview

<img src="SwiftBotApp/Resources/AppIcon.png" alt="SwiftBot App Icon" width="96" />

![SwiftBot UI](App%20Images/Bot%20UI.png)

## Getting Started

1. Create a Discord app in the [Discord Developer Portal](https://discord.com/developers/applications).
2. Add a bot user and copy the bot token.
3. Open `SwiftBot.xcodeproj` in Xcode 15+.
4. Build and run the `SwiftBot` scheme.
5. Paste your token in-app and connect.

Required permissions:
- Send Messages
- View Channels
- Read Message History
- Embed Links
- Send Messages in Threads

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

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [CHANGELOG.md](CHANGELOG.md)
- [AI_GUIDE.md](AI_GUIDE.md)

## Release Notes and Updates

- Stable appcast: [https://johnwatso.github.io/SwiftBot/appcast.xml](https://johnwatso.github.io/SwiftBot/appcast.xml)
- Beta appcast: [https://johnwatso.github.io/SwiftBot/beta/appcast.xml](https://johnwatso.github.io/SwiftBot/beta/appcast.xml)
- Release helper: [`scripts/publish_sparkle_release.sh`](scripts/publish_sparkle_release.sh)

## Contributing

1. Create a feature branch.
2. Make focused changes with clear commit messages.
3. Open a pull request with a summary, screenshots (if UI changes), and test notes.
