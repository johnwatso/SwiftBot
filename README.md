# DiscordBot Native (SwiftUI macOS)

A native macOS Discord bot dashboard app written in SwiftUI and Swift Concurrency (`async/await` + actors). It connects directly to Discord Gateway and REST APIs with no Electron or Node.js runtime.

## Preview

### App Icon

<img src="DiscordBotApp/Resources/AppIcon.png" alt="DiscordBot App Icon" width="96" />

### App UI

![DiscordBot UI](App%20Images/Bot%20UI.png)

## Features

- Native SwiftUI desktop UI pages:
  - Overview
  - Server Notifier
  - Commands
  - Logs
  - Settings
  - Status
- Discord Gateway (`wss://gateway.discord.gg/?v=10&encoding=json`) connection
  - Handles hello, heartbeat, identify, reconnect, and invalid session flow
- Discord REST sending via `https://discord.com/api/v10`
- Server Notifier rule engine:
  - Triggers: user joins/leaves/moves voice, message contains
  - Conditions: server, voice channel, username contains, minimum duration
  - Actions: send message, add log entry, set status
- Voice channel activity tracking with session timing
- Command parsing with configurable prefix (default `!`)
- DM behavior:
  - First DM from a user gets a generic help message
  - Follow-up DMs can use on-device intelligent replies (Beta toggle)
- Persistent settings and rules saved in Application Support JSON

## Commands

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

## On-Device AI DM Replies (Beta)

- Uses Apple on-device Foundation Models when available.
- Controlled via Settings toggle: `Enable on-device intelligent DM replies (Beta)`.
- Disabled by default.

## Build in Xcode

1. Open this folder in Xcode 15+.
2. Open `Package.swift`.
3. Build and run the macOS app target.

## Build Standalone `.app`

Use the helper script to build and package a runnable app bundle:

```bash
./BUILD_APP.sh
```

Optional configuration:

```bash
./BUILD_APP.sh Release
```

Output:

- `Dist/DiscordBotApp.app`

## Intents

The bot identifies with intents bitfield `37639`:

- Guilds (`1`)
- GuildMembers (`2`)
- GuildVoiceStates (`128`)
- GuildMessages (`512`)
- DirectMessages (`4096`)
- MessageContent (`32768`)

## Notes

- For message-based triggers and smart DM behavior, ensure your Discord bot has **Message Content Intent** enabled in the Discord Developer Portal.
- This is a native baseline implementation and can be extended with richer guild/channel/member resolution and expanded rate-limit handling.
