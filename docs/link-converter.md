# SwiftBot Music Link Converter — Detailed Design

> **Status:** Planned (docs-only, no implementation yet).
> **Model:** Odesli-first metadata/link conversion. No audio download, no voice channel, no streaming relay.

---

## Overview

When a user posts a music service URL (Spotify, YouTube, Apple Music, etc.) in a channel, SwiftBot replies with a compact Discord embed containing equivalent links for all other major platforms — so every member can open the track in their preferred app.

---

## Detection

`NSDataDetector` extracts all URLs from the incoming `MESSAGE_CREATE` message content. The result is filtered against known music service domains:

| Service | Matched domains |
|---------|----------------|
| Spotify | `open.spotify.com` |
| YouTube | `youtube.com/watch`, `youtu.be` |
| Apple Music | `music.apple.com` |
| Tidal | `tidal.com` |
| SoundCloud | `soundcloud.com` |
| Deezer | `deezer.com` |
| Amazon Music | `music.amazon.com` |

Only the **first** matched music URL per message is resolved (prevents embed spam on messages that contain several links).

Bot messages are ignored (standard `isBot` guard already in `handleMessageCreate`).

---

## Resolution — Primary: Odesli API

[Odesli](https://odesli.co) (song.link / album.link) is a free music metadata service. No API key is required for low-volume usage (ideal for 10–20 person servers).

**Request:**
```
GET https://api.song.link/v1-alpha.1/links?url=<percent-encoded-url>
```

**Key response fields:**
```json
{
  "entityUniqueId": "SPOTIFY_SONG::...",
  "pageUrl": "https://song.link/s/...",
  "entitiesByUniqueId": {
    "SPOTIFY_SONG::...": {
      "title": "Song Title",
      "artistName": "Artist Name",
      "thumbnailUrl": "https://..."
    }
  },
  "linksByPlatform": {
    "spotify":    { "url": "https://open.spotify.com/..." },
    "youtube":    { "url": "https://www.youtube.com/watch?v=..." },
    "appleMusic": { "url": "https://music.apple.com/..." },
    "tidal":      { "url": "https://tidal.com/..." }
  }
}
```

Only platforms present in `linksByPlatform` are shown. The `title` and `artistName` from `entitiesByUniqueId` populate the embed header.

**Optional:** An Odesli API key can be configured in Settings for higher rate limits.

---

## Confidence Guard

SwiftBot only posts the embed if `linksByPlatform` contains **at least one entry**. If Odesli returns an empty or error response, the bot stays silent — no noisy "couldn't match" messages.

---

## Fallback — Secondary: Metadata API (V2, Opt-In)

If Odesli returns no mapping (e.g., a niche track not in their database), SwiftBot can fall back to direct platform APIs in V2:

| Fallback | API | Requirement |
|---------|-----|-------------|
| YouTube title lookup | YouTube Data API v3 | Operator-configured API key in Settings |
| Spotify track lookup | Spotify Web API | Operator-configured client ID + secret |

Fallback is disabled by default. Operators who configure API keys in Settings unlock this path.

---

## Cache & Rate Limit Guard

To respect Odesli's free-tier rate limits and prevent duplicate embeds:

- **Cache**: guild-scoped, in-memory, keyed on the input URL, 24-hour TTL.
- **Guard**: if the same URL has already been resolved in the same channel within 24 hours, the bot skips the API call and either re-posts the cached embed or stays silent (configurable).

Cache is not persisted across restarts (in-memory only in V1; optional persistence in V2).

---

## Discord Embed Format

```
🎵  Song Title
     by Artist Name

Spotify     →  open.spotify.com/…
YouTube     →  youtube.com/watch?v=…
Apple Music →  music.apple.com/…
Tidal       →  tidal.com/…

Full link card:  song.link/…
```

- Only platforms present in the Odesli response are shown.
- Embed thumbnail uses `thumbnailUrl` from the Odesli entity (V2).
- `pageUrl` (song.link short URL) shown as footer.

---

## Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `musicLinkConversionEnabled` | Bool | `true` | Master toggle |
| `odesliAPIKey` | String | _(empty)_ | Optional; unlocks higher rate limits |
| `musicIgnoredChannelIds` | [String] | _(empty)_ | Channels where conversion is suppressed |
| `musicFallbackEnabled` | Bool | `false` | Enable YouTube/Spotify metadata fallback (V2) |

---

## Integration Points

| File | Change |
|------|--------|
| `AppModel.swift` | Add `MusicLinkConverter.extractMusicURL(from:)` call in `handleMessageCreate`, before command prefix check |
| `AppModel.swift` | Reuse existing `sendEmbed(_:embed:)` for response |
| `BotSettings` | Add above settings fields |
| `RootView.swift` | Add toggle in Settings panel (V1); full Music section (V2) |

No changes to `DiscordService.swift`, `ClusterCoordinator.swift`, or test targets.

---

## New Component: `MusicLinkConverter`

```swift
// Planned interface — no implementation yet
struct MusicLinkConverter {
    /// Extracts the first music service URL from message text, or nil if none found.
    static func extractMusicURL(from text: String) -> URL?

    /// Resolves a music URL via the Odesli API.
    static func resolve(url: URL, apiKey: String?) async -> OdesliResponse?

    /// Builds a Discord embed payload from an Odesli response.
    static func buildEmbed(from response: OdesliResponse, originalURL: URL) -> [String: Any]
}
```

---

## Rollout Phases

### V1 — Core Odesli Integration
- Detection + domain filter
- Odesli API call (no key)
- Embed with platform links (text only, no thumbnail)
- In-memory 24h cache
- `musicLinkConversionEnabled` toggle

### V2 — Polish + Fallback
- Embed thumbnail from `thumbnailUrl`
- Optional Odesli API key support
- Optional YouTube/Spotify metadata fallback
- Ignored-channel list
- Per-guild enable/disable

---

## Legal & Compliance

> SwiftBot provides metadata linking and cross-platform resolution only. No hosting, streaming relay, or downloading of copyrighted material is performed. Operators are responsible for complying with all platform Terms of Service.

- Odesli [Terms of Service](https://odesli.co) permit free, non-commercial API use for link sharing.
- All links in SwiftBot embeds point to the original licensed platforms.
- SwiftBot does not store or cache any music content — only URLs (strings).
- YouTube Data API and Spotify Web API usage (V2 fallback) is subject to their respective developer Terms of Service. Operators who configure these keys accept responsibility for their usage.

---

*Last updated: 2026-03-06 — Design only, no implementation yet.*
