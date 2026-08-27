# finals.id API contract expected by SwiftBot

> **Status (2026-08-27):** finals.id has not shipped public API support yet.
> SwiftBot's provider is built and tested against the sample payload below, but
> live polling stays disabled until the auth scheme and rank endpoint are
> confirmed. Game Tracker is provider-neutral; finals.id is simply the first
> provider registered.

finals.id is the first provider for SwiftBot's provider-neutral Game Tracker service. Its connection remains unavailable for live polling until finals.id confirms the public contract below. SwiftBot schedules and posts ranked-score changes itself; finals.id does not need to schedule or push those announcements.

## Authentication

- Preferred: a finals.id-issued bearer token sent as `Authorization: Bearer <token>`.
- The token is stored in the macOS Keychain and is removed from SwiftBot's on-disk settings file.
- SwiftBot should never receive or store a Steam password, Steam Guard code, Steam session cookie, or refresh token. If Steam sign-in is required, finals.id should complete that flow and issue its own API token afterward.

## Ranked-score endpoint

SwiftBot needs one authenticated `GET` endpoint whose path contains a stable player identifier. The path is configurable using a `{playerID}` placeholder, for example:

```text
GET /v1/players/{playerID}/rank
```

The response must contain an explicit ranked-score field. SwiftBot currently recognises `sr`, `rs`, `rankedScore`, `rankScore`, `ranked_score`, or `rank_score`, including when nested beneath `data`, `result`, `profile`, `ranked`, `ranking`, or `rank`.

Suggested response:

```json
{
  "data": {
    "playerId": "stable-player-id",
    "displayName": "Player#1234",
    "season": "s11",
    "ranked": {
      "rankedScore": 31520,
      "rankName": "Platinum 2",
      "updatedAt": "2026-08-27T09:00:00Z"
    }
  }
}
```

`playerId`, `displayName`, `season`, `rankName`, and `updatedAt` are useful metadata. The ranked score is the only required response value beyond a successful status code. SwiftBot deliberately rejects generic `score` and `combat-score` fields so match statistics cannot be announced as SR.

## Polling behaviour

- Game Tracker polls enabled profiles once daily at the configured local hour (9 AM by default).
- Each profile chooses its game, compatible data provider, stable provider player ID, display name, and Discord destination.
- If SwiftBot starts after that hour and has not attempted the day's check, it catches up immediately.
- The first successful result becomes a silent baseline.
- Unchanged SR produces no Discord post.
- A season change resets the baseline silently, avoiding a false large SR loss.
- Changed players are combined into one Discord embed. Baselines advance only after successful Discord delivery.
- In SwiftMesh, only the Standalone or Primary runtime polls and sends.

Provider credentials and endpoint details live in **Settings → Integrations**. Profiles, baselines, schedules, manual checks, and recent activity live in **Services → Game Tracker**.

## Latest-round data

SwiftBot decodes the “Latest Played Round Result” payload (`season`, `count`, `results`, `nextCursor`) and uses it to build **play-session summaries**, which do not depend on ranked score at all.

A verified sample response for a casual match contains no SR field of any kind. What it does carry per result is:

| Field | Notes |
|---|---|
| `matchId` | Stable match identifier |
| `mode` | Queue type, e.g. `casual`. **Not** `node` — an earlier model misread this |
| `gameMode` | e.g. `TeamDeathmatch` |
| `startedAt` / `endedAt` | ISO-8601 timestamps, used to place a match inside a session window |
| `roundCount`, `kills`, `deaths`, `damage` | Match totals; `damage` is fractional |
| `rounds[]` | Per-round detail: `map`, `twists[]`, `squadName`, `placedAt`, `dbnos`, `respawns`, `roundWon`, `partyMembers` |
| `items[]` | Heterogeneous — some entries carry only `id` and `xp`, others add `kind`/`name`/`slug`/`damage`/`kills` |
| `scorecard` | `assists`, `combat-score`, `elimination-streak`, `eliminations`, `kill-death-ratio`, `support` |
| `roster[]` | Player names |

Decoder notes:

- `combat-score` is **not** SR and is never announced as such. The sample payload confirms this field exists and is a match statistic, which is why the rank decoder rejects it explicitly.
- `partyMembers` has been observed as a single object; the decoder accepts either an object or an array.
- `rounds`, `items`, `roster`, and `twists` decode as optional and surface as empty arrays, so a mode that omits one does not fail the whole response.

## Play-session tracking

Independently of any provider, SwiftBot detects play sessions from Discord rich presence:

- The `GUILD_PRESENCES` intent is already part of the gateway identify bitmask, so no new gateway subscription is needed — it does require the privileged toggle in the Discord developer portal.
- A session starts when a `Playing <game>` activity (activity `type` 0) appears for a linked Discord user, preferring Discord's own `timestamps.start` over first sighting.
- A session ends once that activity has been absent for a grace window (default 3 minutes), which absorbs client restarts and detector glitches. The recorded end time is when the activity vanished, not when the grace expired.
- Sessions shorter than a minimum (default 5 minutes) are discarded silently.
- After a settle delay (default 2 minutes) the provider is queried for the session's matches; a game with no stats provider still gets a duration-only summary labelled as presence-derived.

This path needs `latestSession` capability and a rounds endpoint, but **no** ranked-score endpoint — so it can ship for finals.id before the SR contract is settled, and works for presence-only titles such as Call of Duty that have no usable public API.

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
