# Pairing SwiftBot with Ruru

SwiftBot pairs with a Ruru service using Ruru's single-use **pairing codes**,
such as `7KQ4-M2XP`. A code carries no credentials, so it is safe to read out
or type. Ruru releases the service's connection details only after its operator
approves the request in Ruru. (Earlier pre-release builds used `RURU1:` codes
that embedded the bearer token; that format has been removed.)

## In Ruru

Open the SwiftBot service's **Connection Details → Pair a Server → Create
Code**. The code expires after 10 minutes and can be used once. Ruru notifies
the operator when a server requests pairing, and shows **Approve** and
**Reject** on the service page and in Connection Details.

## In SwiftBot

SwiftMesh → Recovery and Pairing → **Set Up Ruru…**:

1. Enter the code (any case, spaces or a dash; alphabet
   `23456789ABCDEFGHJKMNPQRSTVWXYZ`) and Ruru's HTTPS address.
2. **Request Pairing** runs `RuruShortCodePairing.pair`
   (`Services/MeshWitnessClient.swift`):
   - `POST /v1/pair` with `{"code","nodeID","nodeName"}` and no bearer token.
     The node ID is this Mac's SwiftMesh enrollment ID. Ruru uses the code up
     and returns 202 with a `pairingID`.
   - SwiftBot polls `POST /v1/pair/status` while showing "Waiting for approval
     in Ruru…" (cancellable).
3. On approval (200 with `clusterID` and `token`) SwiftBot shows the address
   and cluster ID for review. Nothing is saved until **Connect**, which stores
   them in Keychain through `MeshWitnessSettingsStore`.

404 `invalid_code` means wrong, used or expired; any other 404 means the Ruru
predates pairing codes. 403 is a rejection, 410 an expiry, 429 too many wrong
codes. Requests time out after 10 minutes. Errors never include the token.

**Advanced** keeps manual entry of the endpoint, cluster ID and bearer token.
Saved settings are carried to failovers in new SwiftMesh Join Codes.

## Adding a backup from the Primary's WebUI

Configure the Primary and connect it to Ruru once. On the backup Mac, install
SwiftBot, open the Primary's HTTPS WebUI, sign in as a Discord admin and choose
**SwiftMesh → Pair SwiftBot → Continue in SwiftBot → Set Up Backup**.

That handoff includes the Primary addresses, a credential enrollment and the
same Ruru service connection. The backup needs no separate Ruru code, bearer
token, Discord bot token or mesh settings. Local confirmation is required on
both fresh and existing installations; the link itself never confirms joining
or enables recording sharing.

Setup closes any previous bot connection, persists the new identity and installs
the Ruru ownership handlers before starting the passive mesh runtime. It verifies
the Primary, authenticates with Ruru's read-only `GET /v1/service`, checks its
lease capability and `/health` readiness, and completes the first configuration
and credential sync. The authenticated Primary health must agree with the
backup's ownership authority. Only after promotion readiness succeeds does it
enable automatic takeover monitoring and persist auto-start. Setup never
acquires a Ruru lease or opens Discord's Gateway.

Errors leave takeover disabled for this setup and offer retry with the same link.
The ordinary throttled settings save is suppressed during setup; pairing owns
ordered persistence so role/term updates cannot complete onboarding prematurely.
The backup's listener port, WebUI, tunnels and companion configuration remain
local. Its own public website and recording sharing can be configured separately;
recording website approval is still an independent Ruru operator decision.

Invitations without Ruru retain peer coordination compatibility and clear a
previous service's Ruru connection. A new Primary reporting Ruru refuses readiness
for such an invitation: generate a fresh link after configuring Ruru. Use matching
SwiftBot builds for this flow.

Lease grants of 3–300 seconds are accepted, matching Ruru's per-service lease
lengths (10–300 seconds).
