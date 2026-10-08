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

Lease grants of 3–300 seconds are accepted, matching Ruru's per-service lease
lengths (10–300 seconds).
