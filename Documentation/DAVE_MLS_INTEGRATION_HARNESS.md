# DAVE MLS Integration Harness Contract

## Status

This is an opt-in integration-test contract, not a fixture. SwiftBot has
deterministic unit coverage for voice lifecycle, DAVE event ordering, media
gating, retries, and recovery. It does not yet prove interoperability with a
genuine MLS peer.

Do not replace this boundary with random binary payloads or a static JSON
replay. An MLS external sender, key package, Welcome/Commit, roster, and media
ratchets are all bound to one group state. A fresh SwiftBot coordinator emits a
fresh key package, so a reusable Welcome also requires the matching private
state. That state must not be checked in.

## Opt-in requirement

The future integration runner must be disabled by default and require an
explicit `SWIFTBOT_DAVE_MLS_INTEGRATION=1` opt-in. Normal `xcodebuild test`
runs must remain self-contained and must not need a Discord account, network
access, or MLS credentials.

The runner needs one of these stateful peers:

1. A controlled harness built from the exact libdave/mlspp source revision
   used by the packaged framework; or
2. A disposable, non-production Discord Voice session using credentials held
   outside the repository.

The current public libdave-swift binary API consumes Discord MLS artifacts; it
does not create an external sender or a matching peer group. Therefore a
static fixture alone cannot satisfy this contract.

## Required flow

Each opt-in run must create a new disposable group and then:

1. Start SwiftBot's normal DAVE voice path and supply the peer's external
   sender.
2. Forward SwiftBot's freshly emitted MLS key package to the stateful peer.
3. Return the peer's matching Welcome or Commit, complete numeric roster, and
   transition ID through the scripted Voice gateway.
4. Assert that SwiftBot sends neither speaking nor media before the matching
   Execute Transition.
5. After Execute, verify that the peer can decrypt an outbound encrypted Opus
   frame and that SwiftBot can decrypt a peer-produced encrypted frame.
6. Apply a second transition and verify both directions re-key.
7. Reset or replace the connection and verify stale gateway/native callbacks
   cannot revive the discarded session.

## Safety and evidence

- Never commit Discord tokens, production guild/account IDs, external sender
  bytes, key packages, Welcome/Commit bytes, private keys, live media, or
  captured encrypted packets.
- Generate all group state for one run only; delete it afterwards and redact
  identifiers from test output.
- Pin and record the libdave source revision used by a controlled harness.
- A failed or unavailable opt-in harness is an integration failure, not a
  reason to weaken the ordinary unit assertions or mark fake data as valid.

The existing scripted coverage lives in
`Tests/SwiftBotTests/VoicePlaybackServiceTests.swift` and
`Tests/SwiftBotTests/VoicePipelineTestSupport.swift`. The upstream package's
`Docs/MLS_INTEGRATION_FIXTURES.md` has the corresponding artifact-level
requirements.
