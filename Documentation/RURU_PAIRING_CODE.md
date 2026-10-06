# Ruru pairing code format (version 1)

A Ruru pairing code hands one guarded service's witness connection to
SwiftBot in a single paste. SwiftBot imports it under SwiftMesh →
**Recovery and Pairing** → **Set Up Ruru…**. The decoder is
`RuruPairingCode` in `Sources/SwiftBot/Services/MeshWitnessClient.swift`.
Ruru's exporter has not been written yet. It must produce codes that this
decoder accepts.

> **The code contains a secret.** It carries the service's bearer token in
> plain base64url. Base64url only encodes the bytes; it does not encrypt
> them. Treat a pairing code like a password: don't log it, post it, or
> leave it in shared notes.

## Layout

```
RURU1:<base64url(UTF-8 JSON)>
```

- The prefix is exactly `RURU1:`. It is case-sensitive, with no spaces.
- The body is base64url (RFC 4648 §5): the alphabet is `A–Z a–z 0–9 - _`,
  with **no `=` padding**. Any other character is rejected, including
  padding, `+`, `/` and whitespace inside the body.
- The whole code, prefix included, must be at most **4096 characters**.
  SwiftBot trims leading and trailing whitespace before checking.

## JSON payload

```json
{
  "version": 1,
  "endpoint": "https://ruru.swiftbot.dev",
  "clusterID": "<service cluster ID>",
  "token": "<service bearer token>",
  "serviceName": "SwiftBot"
}
```

| Field | Required | Rules |
|---|---|---|
| `version` | yes | Integer, must be `1`. Other values fail with an "update SwiftBot" message. |
| `endpoint` | yes | Ruru's app-wide address. Must be `https://`, or `http://` to `127.0.0.1`, `localhost` or `::1` for development. No user info, query or fragment, and no surrounding whitespace. A path is allowed. SwiftBot appends `/v1/lease/{acquire,renew,release}`. |
| `clusterID` | yes | 1–128 UTF-8 bytes, with no leading or trailing whitespace and no control characters. Spaces inside are allowed. Unique to each guarded service. Matches Ruru's own `GuardedService` and `WitnessRouter` checks. |
| `token` | yes | 32–512 UTF-8 bytes, with no whitespace or control characters. The service's own bearer token. Ruru generates 43-character unpadded base64url tokens from 32 random bytes and rejects tokens over 512 bytes. |
| `serviceName` | no | Display metadata only. Trimmed. SwiftBot ignores it, rather than rejecting the code, when it is blank, longer than 64 characters or contains control characters. |

SwiftBot ignores unknown fields, so later fields can be added without
breaking version 1. A change that breaks older readers must use a new
`version`, and the prefix should change with it (`RURU2:`).

Never put these in a pairing code: Ruru's Cloudflare API token, tunnel
credentials, or another service's token.

## Ruru's current Copy output

Until Ruru's exporter exists, its **Guarding → Connection Details → Copy**
(`WitnessAppModel.copyConnectionDetails`) puts bare JSON on the clipboard:

```json
{"clusterID":"swiftmesh-1a2b3c4d","endpoint":"https://witness.example.com","token":"<43 characters>"}
```

SwiftBot accepts this as well. It is any input starting with `{`, with no
`version` or with `"version":1`, and the same field rules apply. Once Ruru
copies `RURU1:` codes, this fallback can stay for older Ruru builds.

## Synthetic fixture

These values are not real credentials. The same string is the
`documentedFixture` in `Tests/SwiftBotTests/RuruPairingCodeTests.swift`.

Payload, compact JSON, keys in this order:

```json
{"version":1,"endpoint":"https://ruru.example.com","clusterID":"swiftbot-example","token":"EXAMPLE-ONLY-0123456789abcdefghijklmnopqrstuv","serviceName":"SwiftBot"}
```

Code:

```
RURU1:eyJ2ZXJzaW9uIjoxLCJlbmRwb2ludCI6Imh0dHBzOi8vcnVydS5leGFtcGxlLmNvbSIsImNsdXN0ZXJJRCI6InN3aWZ0Ym90LWV4YW1wbGUiLCJ0b2tlbiI6IkVYQU1QTEUtT05MWS0wMTIzNDU2Nzg5YWJjZGVmZ2hpamtsbW5vcHFyc3R1diIsInNlcnZpY2VOYW1lIjoiU3dpZnRCb3QifQ
```

Key order and JSON whitespace don't matter to the decoder. An exporter can
check itself by decoding its output, or by encoding the payload above
byte for byte and comparing the result with the code.

## What SwiftBot does with it

1. It decodes and validates the code. Nothing is saved until the user has
   reviewed the service name, address and cluster ID and clicked
   **Connect**.
2. It saves the endpoint, cluster ID and token through
   `MeshWitnessSettingsStore` to the Keychain account
   `swiftbot.mesh.witness`. It writes nothing to settings files and never
   logs the code or the token.
3. It runs the existing `configureMeshRecovery()` path. Lease requests,
   expiry, fencing and Discord output gating are unchanged.
4. New SwiftMesh Failover Join Codes carry the saved witness settings.
   Failovers that are already paired keep their old settings until Ruru is
   set up on them too, or until they are paired again.

If decoding or saving fails, the previous witness settings stay in place.
The manual endpoint, cluster ID and token fields remain under **Advanced**
for installations without a pairing code.
