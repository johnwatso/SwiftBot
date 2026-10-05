# SwiftMesh with a WebUI as the main interface

SwiftMesh keeps one active Discord bot, a preferred Primary Mac, and a paired Failover Mac that can also compute work. Both Macs run the WebUI, with their own public addresses. The backup WebUI provides status while passive and becomes writable when that Mac owns the bot. Companion apps remain on their original host.

## Pairing and addresses

1. Configure the preferred Primary normally. Enable its WebUI and public address, for example `https://swiftbot.example.com`.
2. Configure the backup Mac's WebUI with its own address, for example `https://swiftbot2.example.com`, and a separate Cloudflare tunnel. A backup tunnel carries only that Mac's local services.
3. Generate a fresh SwiftMesh Join Code on the Primary, then paste it on the Failover. New codes include a unique credential enrollment in addition to the shared mesh transport key. Old codes must be regenerated to enable credential sync.
4. Keep the code private: a paired Failover is trusted with the Discord bot token, OAuth secret, essential provider credentials, and the credential approval list. Approvals are stored in Keychain. Possessing only the common mesh key does not authorize the credential endpoints.
5. Register the OAuth callbacks for both hostnames in the same Discord application. Use each WebUI's displayed callback path; the default is `/auth/discord/callback`. Discord associates the redirect with the registered application URL. [Discord OAuth2 reference](https://docs.discord.com/developers/topics/oauth2).
6. Confirm a shared-state sync before relying on the Failover. Promotion checks for an imported configuration, loaded automations, a Discord token, and the node's credential approval.

A Cloudflare **API token** provisions or changes tunnels and DNS. A **tunnel token** runs a particular existing tunnel. SwiftBot's built-in provisioning UI needs an API token on the Mac where provisioning takes place. It remains local and is never replicated. Alternatively, the account owner can provision a dedicated backup tunnel externally and run its connector on the backup Mac using that tunnel's token. A remotely managed tunnel only needs its tunnel token to run. [Cloudflare tunnel tokens](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/).

Do not give the Failover the Primary's tunnel token. A second connector to that tunnel would also receive routes for companion services that only exist on the Primary Mac. Each Mac keeps its tunnel token, hostname, DNS account information, recording locations, local password, browser sessions, and passkeys.

Public HTTPS URLs use port 443. Bare LAN/private-overlay hostnames use the configured mesh port. Followers can pull shared configuration, history, and tasks through the Primary's WebUI address; computation does not require inbound access to the worker. If an external Cloudflare Access policy protects the hostname, mesh requests must also be allowed by that policy; an interactive browser login cannot satisfy the mesh client.

## Takeover and return

The Failover checks the active node's authenticated mesh health, including the intended bot state and Discord connectivity. Three missed checks start confirmation and a final best-effort resync before promotion. An alive Primary with broken Discord can instead transfer ownership through the same coordinated protocol. A deliberate pause reported by a reachable owner is respected.

The configured role is a preference; the elected runtime role controls output, replication, and write access. Saving preferences cannot reset a promoted Failover to Standby or re-enable a returning Primary prematurely. Leadership terms never decrease, including during re-pairing. The Primary remembers paired peer addresses so a restart can discover the temporary owner.

Automatic return to the preferred Primary is enabled by default. It waits for 60 seconds of stable health, or the longer window configured in SwiftMesh. Return works as follows:

1. The returning Primary requests a transfer from the active owner.
2. The active owner freezes WebUI mutations and bot output, drains admitted automation effects, pauses monitoring, and saves shared state.
3. The returning node imports the frozen configuration and credentials, pages conversation history, and checks configuration again.
4. The active owner closes its Discord gateway and relinquishes leadership before acknowledging the commit.
5. The returning Primary acquires ownership, opens Discord, and resumes saved automation runs.

Failed catchup aborts the transfer and resumes the current owner. An unconfirmed commit leaves the requesting node passive. The transfer times out after 90 seconds if it has not committed. Handover-test expiry does not blindly drop the remaining owner after a failed return notification.

## Independent ownership witness

Peer coordination alone cannot distinguish a dead Mac from a partition between two live Macs. For exclusive takeover during partitions, configure the optional witness under the native console's SwiftMesh **Recovery and Pairing** section. Use one independent authority reachable by both Macs; do not run it solely on either bot Mac.

The preferred authority is now **SwiftMesh Witness**, a separate native macOS Xcode app. Its independent repository targets macOS 15 (Sequoia), with Intel and Apple silicon Release binaries. The first planned host is the 2012 Intel/OpenCore Mac mini in Invercargill. It provides a menu bar service, ownership history, Keychain credential, and connection details without running a bot or companion apps. Closing its window keeps the service running; this initial app requires a logged-in user session and a Mac that stays awake.

Install the witness app on the independent Mac and use its Internet Access setup to enter a Cloudflare API token and a dedicated hostname. It creates and runs its own tunnel to the loopback listener; no separate reverse proxy is required. Open Connection Details to obtain its endpoint, cluster ID, and bearer token, then enter those under SwiftBot's Recovery and Pairing settings. The Python implementation under `Tools/SwiftMeshWitness/` remains a development protocol reference; use the separate app's README for deployment.

The default listener is `127.0.0.1:38990`. Configure the HTTPS endpoint, a stable cluster ID, and the bearer token on trusted nodes. New Failover Join Codes include this witness configuration; existing paired nodes need the same configuration saved locally. Provisioning and deployment are separate from building SwiftBot.

SwiftBot includes its configured SwiftMesh node name as optional display metadata
on witness requests. The witness shows that name in Overview and Activity;
existing bot builds can be given a local nickname through Bot Details. Ownership
continues to use the stable node ID and term. Changing a name preserves the
client's current lease and deadline and never determines Primary preference.

The witness grants one owner per cluster, uses monotonically increasing terms, and refuses expired renewals. Live expiry uses a monotonic clock. After a witness restart with outstanding leases, it waits a full 30-second lease before new acquisitions; a wall-clock change or reboot cannot prematurely release the previous owner's lease. The owner renews every five seconds. SwiftBot's Discord output gate and WebUI write gate check a local monotonic lease deadline even if the renewal task stalls. Loss of the witness stops bot output instead of permitting both Macs to operate. This trades availability for exclusive ownership when the authority is unavailable.

The protocol fences ownership decisions; already-sent Discord HTTP requests can still complete. Discord does not enforce SwiftMesh fencing tokens. This is not a guarantee of exactly-once external effects.

## What is shared

The snapshot is an explicit allowlist, with a complete manifest, deletions, a persisted `(leader term, revision)`, bounded sizes, and a disk transaction journal. Unknown files, malformed automation/checkpoint data, stale revisions, and conflicting content at the same revision are rejected before installation. Local machine configuration is merged rather than overwritten.

Shared state includes bot behavior, Automations, essential game-provider configuration, voice/community history, command cooldowns, and saved automation executions. Wiki context and conversation records use the existing mesh replication routes. Conversation cursors follow chronological record order; UUIDs are opaque identities, not timestamps. Cursor timestamps supplement the older ID-only cursor format.

The encrypted credential response requires both mesh authentication and an Ed25519 signature from an approved node. Each node keeps its private signing key in Keychain; only that node's Join Code carries it. The authoritative approval list replicates public verification keys, so one node cannot impersonate another after its own approval is revoked. The response includes the Discord bot token, Discord OAuth secret, and essential game-provider tokens. Cloudflare and SwiftMiner credentials are excluded. Revoking a pairing blocks future secret fetches; it cannot erase secrets already copied to another Mac. Remove an untrusted node by rotating the shared transport key and any credentials it previously received.

## Automation and computation recovery

Automation executions save their next step, due time, AI output, and event context before and after effects. Delays resume from their due time after promotion and Discord READY. Completed message-triggered runs are deduplicated by rule and message ID. Disabled or deleted rules do not resume.

An action that was admitted but not acknowledged before a crash is reported as **Needs review** in the automation log and is held rather than automatically repeated. A crash can occur after Discord accepted an action but before the checkpoint was saved. Review the destination before manually repeating it. Checkpoints contain no bot token and retain completed entries for seven days, with a 1,000-entry bound.

New nodes poll for typed AI-reply, Wiki-lookup, and playlist-import jobs over an outbound connection. Jobs carry a stable UUID, input hash, leader term, deadline, and attempt. Worker results are persisted and deduplicated across retries/restarts; conflicting inputs, expired jobs, obsolete leadership, and exhausted capacity are rejected. Worker capacity is two computations; dispatch waits at most 25 seconds before local fallback. Workers never send the computed result to Discord themselves. Legacy peers retain their older direct-request fallback until upgraded.

Routine follower sync runs every 15 seconds. A sudden Primary crash can lose events/checkpoints since the last successful sync. The standby connects to Discord only after promotion, so Gateway events in that connection gap are not guaranteed to be recovered. This implementation does not provide lossless event ingestion, shared browser sessions, companion-app relocation, or cross-host recording availability.

## Validation and rollout

Use matching builds on both Macs. Tests cover ownership refusal/expiry, monotonic terms, coordinated and aborted handback, authenticated WebUI mesh routing, outbound-only offloading, revisioned snapshot import, durable job deduplication, and delayed/ambiguous automation recovery. The witness has independent concurrency, expiry, restart, and fencing tests.

Before production rollout, configure both addresses and OAuth callbacks, deploy the independent witness if partition safety is required, then run a controlled two-Mac failure and return drill. Repository tests do not exercise live Discord, a live Cloudflare tunnel, or a deployed witness.
