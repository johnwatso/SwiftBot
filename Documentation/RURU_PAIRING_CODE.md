# Pairing SwiftBot with Ruru

SwiftBot pairs with a Ruru service using Ruru's single-use **pairing codes**,
such as `7KQ4-M2XP`. A code carries no credentials, so it is safe to read out
or type. Ruru releases the service's connection details only after its operator
approves the request in Ruru. (Earlier pre-release builds used `RURU1:` codes
that embedded the bearer token; that format has been removed.)

## In Ruru

Open the SwiftBot service's **Connection Details → Pair a Server → Create
Code**. Once Ruru has a public address it also shows one copyable line with
the address and the code, such as `ruru.example.com 7KQ4-M2XP`
(RuruClient's `RuruPairingInvite`); it carries no credentials. The code expires after 10 minutes and can be used once. Ruru notifies
the operator when a server requests pairing, and shows **Approve** and
**Reject** on the service page and in Connection Details.

## In SwiftBot

SwiftMesh → Ruru → **Set Up Ruru…**:

1. Paste the line from Ruru, which fills both fields, or enter the code (any
   case, spaces or a dash; alphabet `23456789ABCDEFGHJKMNPQRSTVWXYZ`) and
   Ruru's HTTPS address separately.
2. **Request Pairing** runs `RuruPairing.pair`
   (`Services/MeshWitnessClient.swift`):
   - `POST /v1/pair` with `{"code","nodeID","nodeName"}` and no bearer token.
     The node ID is this Mac's SwiftMesh enrollment ID. Ruru uses the code up
     and returns 202 with a `pairingID`.
   - SwiftBot polls `POST /v1/pair/status` while showing "Waiting for approval
     in Ruru…" (cancellable).
3. On approval (200 with `clusterID` and `token`) SwiftBot saves them to
   Keychain through `MeshWitnessSettingsStore` and closes the sheet. Approving
   the named server in Ruru is the confirmation; there is no second Connect step.

404 `invalid_code` means wrong, used or expired; any other 404 means the Ruru
predates pairing codes. 403 is a rejection, 410 an expiry, 429 too many wrong
codes. Requests time out after 10 minutes. Errors never include the token.

The WebUI offers the same pairing on **SwiftMesh → Ruru → Connect Ruru…**
(admin, CSRF-checked `ruruPair` / `ruruPairCancel` actions). The browser sends
only the pasted line; the token Ruru releases goes straight to this Mac's
Keychain and never reaches the browser. The WebUI only makes a first
connection: changing or disconnecting Ruru stays in the native app.

**Advanced** keeps manual entry of the endpoint, cluster ID and bearer token.
Each Mac must pair with Ruru itself: a node-bound token belongs only to the Mac
for which Ruru issued it. Credential sync no longer sends or saves a Ruru
connection. If an older Primary sends one for a different configured authority,
credential sync stops. A backup that already inherited a Primary's token keeps
it until that Mac is paired again.

## Backup enrollment status

The former Primary WebUI Join Code flow was removed in the SwiftMesh
simplification. Pairing both Macs with Ruru does not discover the Primary,
approve SwiftMesh credential access, or complete initial configuration sync.
A complete Ruru-led enrollment flow remains to be implemented and validated
on two Macs. Existing peer-only deployments are not protected against network
partitions by Ruru.

Lease grants of 10–300 seconds are accepted, matching Ruru's per-service lease
lengths. New SwiftBot services use 300 seconds; existing services retain their
configured duration.
