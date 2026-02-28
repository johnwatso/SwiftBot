# DiscordBot Native (SwiftUI macOS)

A native macOS Discord bot dashboard app written in SwiftUI and Swift Concurrency (async/await + actors). The app connects directly to Discord Gateway + REST APIs without Electron or Node.js.

## Preview

### App Icon

<img src="DiscordBotApp/Resources/AppIcon.png" alt="DiscordBot App Icon" width="120" />

### App UI

![DiscordBot UI](App%20Images/Bot%20UI.png)

## Features

- Native SwiftUI desktop UI with sidebar pages:
  - Overview
  - Voice
  - Commands
  - Logs
  - Settings
- Discord Gateway (`wss://gateway.discord.gg/?v=10&encoding=json`) connection
  - Handles Hello, Heartbeat, Identify, Reconnect and Invalid Session opcodes
- Discord REST sending via `https://discord.com/api/v10`
- Voice join/leave/move tracking with in-memory session timing
- Command parsing with configurable prefix (default `!`)
- Persistent app settings in Application Support JSON

## Commands implemented

- `!help`
- `!ping`
- `!roll NdS`
- `!8ball <question>`
- `!poll "Question" "Option 1" "Option 2"`
- `!userinfo [@user]`
- `!setchannel #channel`
- `!ignorechannel #channel|list|remove #channel`
- `!notifystatus`

Unknown commands return:

`❓ I don't know that command! Type !help to see all available commands.`

DMs without prefix return:

`👋 Hey there! If you need help, type !help to see what I can do!`

## Build in Xcode

1. Open the folder in Xcode 15+.
2. Open `Package.swift` (or add sources to a macOS App target).
3. Set deployment target macOS 13.0+.
4. Run on an Apple Silicon Mac (arm64).

## Intents

This implementation identifies with intents bitfield `37639`:

- Guilds (1)
- GuildMembers (2)
- GuildVoiceStates (128)
- GuildMessages (512)
- DirectMessages (4096)
- MessageContent (32768)

## Notes

- This is a full native baseline implementation intended to be extended with richer guild/channel/member resolution and robust REST rate-limit bucket management.
