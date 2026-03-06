# SwiftBot Music Link Converter — Architecture & Setup Guide

> **Status:** Planned (design phase). Inspired by [tunes.ninja](https://tunes.ninja).
> **Model:** Detect a music link in chat → fetch cross-platform links from Odesli API → post a Discord embed so everyone can open the track in their preferred app.

---

## What It Does

When a user posts a Spotify, YouTube, Apple Music, or other music service link in a channel, SwiftBot automatically replies with a clean embed containing equivalent links for all major platforms — so Android, iPhone, and browser users all get a usable link regardless of what the original poster shared.

No voice channel, no audio download, no playback. Pure link conversion.

---

## Flow

```
User posts message containing a music URL
    ↓
AppModel.handleMessageCreate()
    ↓
MusicLinkConverter.extractMusicURL(from: content)   [NSDataDetector + domain filter]
    ↓
MusicLinkConverter.resolve(url:)                     [GET api.song.link/v1-alpha.1/links]
    ↓
MusicLinkConverter.buildEmbed(response:)             [format Discord embed]
    ↓
AppModel.sendEmbed(channelId, embed:)                [existing REST path]
```

---

## Link Detection

`NSDataDetector` extracts all URLs from the message. The result is filtered against known music service domains:

| Service | Domain pattern |
|---------|---------------|
| Spotify | `open.spotify.com` |
| YouTube | `youtube.com/watch`, `youtu.be` |
| Apple Music | `music.apple.com` |
| Tidal | `tidal.com` |
| SoundCloud | `soundcloud.com` |
| Deezer | `deezer.com` |
| Amazon Music | `music.amazon.com` |

Only the first matched music URL per message is resolved (avoids spam on messages that contain multiple links).

---

## Odesli API

[Odesli](https://odesli.co) (also known as song.link / album.link) is a free, publicly accessible music metadata service. No API key is required for low-volume usage — ideal for a 10–20 person server.

**Request:**
```
GET https://api.song.link/v1-alpha.1/links?url=<percent-encoded-url>
```

**Response (relevant fields):**
```json
{
  "pageUrl": "https://song.link/s/...",
  "entitiesByUniqueId": { ... },
  "linksByPlatform": {
    "spotify":    { "url": "https://open.spotify.com/..." },
    "youtube":    { "url": "https://www.youtube.com/watch?v=..." },
    "appleMusic": { "url": "https://music.apple.com/..." },
    "tidal":      { "url": "https://tidal.com/..." }
  }
}
```

Only platforms present in `linksByPlatform` are shown in the embed.

**Rate limits:** Odesli free tier is suitable for small servers. For higher volume, an API key can be configured in Settings.

---

## Discord Embed Format

```
🎵 Also available on…

Spotify     →  [open.spotify.com/…]
YouTube     →  [youtube.com/watch?v=…]
Apple Music →  [music.apple.com/…]
Tidal       →  [tidal.com/…]

Full links: song.link/…
```

Implemented as a Discord `embeds` payload via the existing `sendEmbed(_:embed:)` path in `AppModel`.

---

## Integration with Existing SwiftBot Stack

| Existing Component | Music Link Extension |
|-------------------|---------------------|
| `AppModel.handleMessageCreate()` | Call `MusicLinkConverter` before command check; skip if no music URL found |
| `AppModel.sendEmbed()` | Already exists — reused directly |
| `DiscordService` | No changes; REST path already handles any payload shape |
| `BotSettings` | Add `musicLinkConversionEnabled: Bool` toggle (default: true) |
| `BotSettings` | Add optional `odesliAPIKey: String` for higher rate limits |

**No new SPM dependencies. No new imports.**

---

## New Component: `MusicLinkConverter`

A lightweight struct (or actor if rate-limit state is needed):

```swift
struct MusicLinkConverter {
    static func extractMusicURL(from text: String) -> URL?
    static func resolve(url: URL, apiKey: String?) async -> OdesliResponse?
    static func buildEmbed(from response: OdesliResponse, originalURL: URL) -> [String: Any]
}
```

---

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Music link conversion enabled | `true` | Toggle auto-conversion on/off |
| Odesli API key | _(empty)_ | Optional; for higher rate limits |
| Channels to ignore | _(empty)_ | Channels where conversion is suppressed |

---

## Legal & ToS

- **No audio is downloaded or streamed.** This feature only calls the Odesli metadata API and posts links.
- Odesli [Terms of Service](https://odesli.co) allow free, non-commercial API access for link sharing.
- All music links posted remain links to the original licensed platforms — no copyright concerns.
- SwiftBot does not store or cache any music content.

---

## Rollout Phases

### V1 — Core Link Conversion
- `NSDataDetector` URL extraction + domain filter
- Odesli API call (no key required)
- Basic embed: platform name + link
- `musicLinkConversionEnabled` toggle in Settings

### V2 — Polish
- Configurable ignore-channel list
- Optional Odesli API key support
- Embed thumbnail from track artwork (Odesli provides `thumbnailUrl`)
- Per-guild enable/disable

---

*Last updated: 2026-03-06 — Design only, no implementation yet.*
