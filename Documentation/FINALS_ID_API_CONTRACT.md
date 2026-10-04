# finals.id API as used by SwiftBot

> **Status (2026-10-01):** finals.id's public API is live and documented at
> <https://api.finals.id/> (OpenAPI: `/v1/openapi.json`). SwiftBot's provider
> was rebuilt against it and verified with a personal key: rank, rounds and
> error handling all work against real responses. The earlier proposal this
> file used to describe (`/v1/players/{id}/rank`, nested match objects, a
> `mode` queue field) never shipped.

finals.id is the first provider for SwiftBot's provider-neutral Game Tracker. SwiftBot schedules checks and posts ranked-score changes itself; finals.id only answers requests.

## Authentication

- `Authorization: Bearer ftk_…`. A personal key can read the key owner's data and public fields other players' privacy settings allow.
- The token is stored in the macOS Keychain (`game-provider-token-finalsID`), never in settings.json.
- SwiftBot never handles Steam or Embark credentials.

## Player identifier

Every profile path takes `{username}`: the player's current name **including the `#tag`** (e.g. `name#1234`), a previous name, or their public id (`p-…`). SwiftBot percent-encodes it as a single path segment (`#` becomes `%23`).

## Ranked score — `GET /v1/profiles/{username}`

The built-in rank endpoint template is `/v1/profiles/{playerID}`. A blank template, or the old guess `/v1/players/{playerID}/rank`, resolves to it automatically; any other template an operator types is kept.

The profile card carries the current-season standing under a top-level `ranked` block:

```json
{
  "id": "p-…", "username": "name#1234", "season": "s11",
  "ranked": { "boardId": "s11", "score": 28160, "rankIndex": 12, "leagueName": "Gold", "globalRank": 56866, "capturedAt": "2026-10-01T03:50:17.796427Z" },
  "rankScoreHidden": false
}
```

- **SR** is `ranked.score`. A bare `score` is only trusted inside that top-level `ranked` block; anywhere else it could be a match's combat score, which must never be announced as SR. Other providers still go through the generic decoder, which requires an explicit `sr`/`rankedScore`-style key.
- **Rank name** is resolved to a division such as "Gold 1" (`GameRankTiers.swift`): `ranked.rankIndex` runs 1 (Bronze 4) → 20 (Diamond 1), 21 is Ruby, and must agree with `ranked.leagueName`; otherwise the 2,500-SR division bands decide, then the league alone. `rankIndex` is still stored as the Rank metric so promotions can trigger announcements.
- **Leaderboard** `ranked.globalRank` is stored as the Leaderboard metric and shown on rank cards; it is not offered as a trigger.
- **Season** is `season` (falling back to `ranked.boardId`); a season change resets the baseline silently.
- **Time** is `ranked.capturedAt` (fractional seconds).
- `rankScoreHidden: true`, or HTTP 403, means the player hid their SR → "This player has hidden their ranked score". `ranked: null` means no standing this season → "no ranked score this season yet". HTTP 404 means the name doesn't resolve → a hint to include the `#tag`.

## Rounds — `GET /v1/profiles/{username}/rounds`

Used for play-session summaries. Results are **flat rounds**, newest first, `limit` 50 by default:

| Field | Notes |
|---|---|
| `roundId`, `matchId` | A match is one round, or several rounds sharing a `matchId` (ranked and tournament modes) |
| `gameMode` | e.g. `QuickCash`, `PointBreak`, `Ranked`; sometimes absent |
| `startedAt` / `endedAt` | ISO-8601 |
| `kills`, `deaths`, `damage`, `placedAt`, `dbnos`, `respawns`, … | Optional per round |
| `roundWon`, `tournamentWon` | A multi-round match counts as won only when `tournamentWon` is set |
| `partyMembers` | Observed as a single object; the decoder also accepts an array |
| `private` | Present on rounds the player hid: only ids, `mode` and timing — skipped |

SwiftBot groups rounds into matches (`FinalsIDPlayedMatch`): kills, deaths and damage summed across rounds, ranked when `gameMode` contains "Ranked", started at the earliest round.

## Other endpoints worth knowing

- `GET /v1/profiles/{username}/sessions` — finals.id's own play sessions with match, win, ranked and kill totals. SwiftBot defines sessions from Discord presence instead, so it doesn't use this yet.
- `GET /v1/profiles/{username}/rank-history` — SR over time; SwiftBot records its own readings for Analytics instead.

## Polling behaviour

- Game Tracker polls enabled profiles once daily at the configured local hour (9 AM by default), catching up immediately if SwiftBot starts after that hour.
- The first successful result becomes a silent baseline; unchanged SR posts nothing; a season change resets the baseline silently.
- Changed players are combined into one Discord embed. Baselines advance only after successful delivery.
- Each successful reading is also recorded for the Analytics "Ranked progress" chart.
- In SwiftMesh, only the Standalone or Primary runtime polls and sends.

## Play-session tracking

Independently of any provider, SwiftBot detects play sessions from Discord rich presence:

- The `GUILD_PRESENCES` intent is already part of the gateway identify bitmask, so no new gateway subscription is needed — it does require the privileged toggle in the Discord developer portal.
- A session starts when a `Playing <game>` activity (activity `type` 0) appears for a linked Discord user, preferring Discord's own `timestamps.start` over first sighting.
- A session ends once that activity has been absent for a grace window (default 3 minutes), which absorbs client restarts and detector glitches. The recorded end time is when the activity vanished, not when the grace expired.
- Sessions shorter than a minimum (default 5 minutes) are discarded silently.
- After a settle delay (default 2 minutes) the provider is queried for the session's matches; a game with no stats provider still gets a duration-only summary labelled as presence-derived.

This path needs `latestSession` capability and a rounds endpoint, but **no** ranked-score endpoint, so it also works for presence-only titles such as Call of Duty that have no usable public API.

## Items finals.id still needs to confirm

1. API base URL.
2. Bearer-token issuance and revocation flow.
3. Ranked-score endpoint path and stable player identifier.
4. Exact explicit SR field and season semantics.
5. Rate limits and whether conditional requests or caching headers are supported.
6. The path for the latest-played-round listing, and whether it accepts a time or cursor bound so a session summary can fetch only that session's matches.
7. Whether `mode` reports a distinct value for rated queues (the sample only shows `casual`).

## Provider abstraction

Game Tracker is not finals.id-specific. A provider is registered by adding a `GameProviderCatalog` descriptor and a `GameRankProvider` implementation to `GameProviderRegistry`; nothing else in the app names a concrete provider.

A descriptor declares its own auth style, so a provider that uses an API-key header (tracker.gg's `TRN-Api-Key`) or a query parameter (Steam's `key=`) needs no new credential-handling code. Credentials live in the Keychain under `game-provider-token-<providerID>`.

Capabilities are declared per provider (`rankedScore`, `rankTier`, `latestSession`, `matchHistory`) and are enforced: a provider that cannot report a ranked score is never asked for one and is not required to supply a rank endpoint.
