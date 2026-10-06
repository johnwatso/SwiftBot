# SwiftMesh and Ruru review for 2.0 — 7 October 2026

Reviewed SwiftMesh ownership, failover, coordinated handback and the Ruru integration in SwiftBot at `629585c` (`2.0-prep`), together with Ruru at `bf35c18` (`~/Documents/GitHub/ruru`). Both are traced from code; nothing here was observed on live Macs, and no code was changed. The [drill plan](#live-drill-plan) at the end turns the findings into checks for the two-Mac test.

P1 means a gap to fix before relying on SwiftMesh in 2.0; P2 is a recovery path that works but slowly or confusingly; P3 is an improvement.

**Status (later on 7 October 2026):** findings 1–3 are fixed in SwiftBot, each with a **Fixed** note below. Findings 4–6 and the optional Ruru changes are still open. Ruru was not changed.

The core protocol is in good shape. The handback freeze/drain/commit sequence is idempotent and times out safely. Ruru's terms only increase, it persists before granting, and it quarantines after a restart. The Preferred Primary tracker rejects stale, out-of-order and contradictory reads. Every Discord effect in `DiscordService` checks `outputAllowed`, including the local lease deadline. The problems are in what happens around the lease: losing it is too easy, and getting it back is sometimes impossible without an operator.

## Findings

1. **[P1] One failed lease renewal demotes the Primary, and a Primary with no leader address never tries again.**

   [ClusterCoordinator.swift:417](../Sources/SwiftBot/ClusterCoordinator.swift#L417), [ClusterCoordinator.swift:348](../Sources/SwiftBot/ClusterCoordinator.swift#L348), [ClusterCoordinator.swift:1491](../Sources/SwiftBot/ClusterCoordinator.swift#L1491), [ClusterCoordinator.swift:2658](../Sources/SwiftBot/ClusterCoordinator.swift#L2658).

   `renewOwnership` demotes on the first `false` from `renew`, although the lease still has about 23 seconds left (30-second lease, renewed every 5 seconds). `MeshWitnessClient` returns `false` for anything that isn't a 200 within its 5-second timeout. That includes a single slow request through Cloudflare to the Mac mini, and it doesn't distinguish "lost the lease" from "couldn't reach Ruru". `setOwnershipHandlers` and `applySettings` make the same one-shot decision at startup and fall back to Standby.

   Once demoted, the only automatic routes back to ownership are the Standby health monitor and handback, and both need a leader address. The configured Primary normally has none (the handback tests configure it with `leaderAddress: ""`), so `restartStandbyMonitorIfNeeded` returns without starting a monitor. Consequences:
   - **With the Failover running:** the Failover counts three misses, confirms and promotes after roughly 60–75 seconds, then hands back after its stable window. That's two Discord reconnects and about a minute offline, caused by one slow request.
   - **With the Failover off** (maintenance, or a single Mac using Ruru): the bot stays offline until someone promotes manually or restarts the app.
   - **At boot:** if Ruru is unreachable or still in its restart quarantine when the Primary starts, the Primary starts as Standby and stays there.

   Fix in SwiftBot:
   - Keep retrying a failed renewal until the local deadline. Demote (closing the Gateway, not just output) only when the deadline passes or Ruru answers `ownership_expired_or_changed`.
   - After losing the lease, a Standby that is the configured Primary, or Ruru's preferred node, should keep calling `acquire` on a backoff while no healthy leader is known. Ruru arbitrates, so these attempts are safe.
   - Have `MeshWitnessClient` return Ruru's error code (`ownership_expired_or_changed`, `ownership_held`, `authority_recovering`, unauthorized) instead of `nil`.

   Tests: a renewal that fails once still owns; a renewal that keeps failing demotes at the deadline; a lone demoted Primary regains the lease when Ruru recovers; startup during quarantine ends up owning.

   **Fixed.** `MeshWitnessClient.renew` returns `MeshOwnershipRenewal`. A 401, 403 or 409 is `.lost`. A timeout, network failure or 503 is `.unreachable(stillValid:)`, judged against the local deadline. `renewOwnership` retries an unanswered renewal every 2 seconds and demotes only on `.lost` or once the deadline has passed. A new ownership-recovery loop (`startOwnershipRecoveryIfNeeded`) runs on a witness-backed Standby that has no leader to monitor and is the configured Primary or Ruru's preferred node. Every 5 seconds it goes through `promoteToLeader`, so readiness checks and Ruru arbitration still apply. It also starts when the Primary policy arrives after a failed startup acquire, which is the order AppModel uses at launch. Tests: `testUnansweredRenewalKeepsTheLeaseWhileItIsValid`, `testLonePrimaryRecoversAfterRuruRestarts`, `testPrimaryStartedWithoutALeaseAcquiresOneWhenRuruReturns`, `testLostLeaseToAnotherMacIsNotTakenBack` and `MeshReliabilityTests.testRenewalSeparatesRefusalFromNoAnswer`.

2. **[P1] Every Ruru restart, including a Sparkle update, ends the active lease.**

   Ruru [LeaseStore.swift:51](../../ruru/Sources/WitnessKit/LeaseStore.swift#L51), [LeaseStore.swift:67](../../ruru/Sources/WitnessKit/LeaseStore.swift#L67), [LeaseStore.swift:90](../../ruru/Sources/WitnessKit/LeaseStore.swift#L90).

   This is by design: a new process gets a new monotonic epoch, quarantines for 30 seconds, and leases from the previous process can't be renewed. Combined with finding 1, though, each Ruru update, reboot or crash forces a full SwiftBot failover and handback. Ruru updates install on quit, so this happens whenever someone installs one.

   With finding 1 fixed, a Ruru restart becomes a pause of about 30–40 seconds: the Primary's renewals fail, its deadline passes, and it acquires a new term once Ruru leaves quarantine. Nobody else can take over during the quarantine.

   **Optional change in Ruru (your decision, because it changes a documented invariant).** Make restarts within the same boot seamless. Store lease expiry as system continuous time (`mach_continuous_time`, which keeps running across process restarts and sleep) together with `kern.bootsessionuuid`. After a same-boot restart, previous leases keep their exact deadlines and renewals continue. A changed boot session still gets the full quarantine. This replaces the "full quarantine after process restart" rule in Ruru's `AGENTS.md` with "full quarantine after reboot". It is as safe as long as continuous time is monotonic within a boot, which it is.

   Smaller Ruru change: before installing an update or quitting with a live lease, say that guarded services will pause for about 30 seconds.

   **Fixed on the SwiftBot side** through finding 1. `testLonePrimaryRecoversAfterRuruRestarts` models a Ruru restart: the Primary pauses and then takes a new term. The two Ruru changes above remain optional and are not done.

3. **[P1] A Mac without Ruru configured can take over, so partition safety depends on both Macs being set up identically.**

   [ClusterModels.swift:1116](../Sources/SwiftBot/Models/ClusterModels.swift#L1116).

   Ruru's settings live in each Mac's Keychain and aren't replicated, and `MeshNodeHealth` doesn't say whether a node uses a witness. Suppose a Failover was paired with a Join Code from before Ruru was set up, has had Ruru removed, or holds a different cluster ID. It then promotes through peer coordination alone. Under the exact partition Ruru exists for (the Macs can't see each other but both can reach Discord), that gives two owners.

   Fix in SwiftBot: the Primary publishes a non-secret "ownership via Ruru" marker (cluster ID and endpoint host) in the replicated settings and in its health. A Standby whose local witness doesn't match refuses to promote and explains why. The SwiftMesh dashboard flags the mismatch on both Macs. Test: a Standby with no witness, under a Primary that has one, does not promote when the Primary disappears.

   **Fixed (Standby side).** `MeshNodeHealth.ownershipWitness` carries the node's `MeshWitnessConfiguration.ownershipFingerprint`, which is `clusterID@host` with no token. A Standby records the owner's fingerprint from its health checks and persists it in the cluster recovery state, so it still applies after the owner disappears. `promoteToLeader` and `requestCoordinatedHandback` refuse on a mismatch and say why in SwiftMesh diagnostics. A handback refreshes the owner's health before freezing it and checks again before commit. A promotion that follows a committed handback is never refused, because the owner has already stopped. A test run caught that race. Not done: the Primary flagging a mismatched Standby. Its dashboard still shows nothing, so check the Standby's SwiftMesh diagnostics. Builds from before this check report no fingerprint and are not held to it. Tests: `testStandbyWithoutTheOwnersRuruCannotTakeOver`, `testStandbyWithADifferentRuruCannotTakeOver`, `testMatchingRuruStillHandsBack` and `testRuruFingerprintOmitsTheToken`.

4. **[P2] Saving witness settings on the live Primary applies them without checking them.**

   [MeshRecoveryPreferences.swift:78](../Sources/SwiftBot/MeshRecoveryPreferences.swift#L78), [AppModel+MeshRecovery.swift:26](../Sources/SwiftBot/AppModel+MeshRecovery.swift#L26).

   Connect saves to the Keychain and immediately runs `configureMeshRecovery`, which acquires from the new endpoint. A typo'd token, a wrong cluster ID or an unreachable hostname means the acquire fails, so the Primary demotes and (finding 1) doesn't come back.

   Fix: before saving, call `GET /health` and the authenticated `POST /v1/service/policy`. A 200 proves the endpoint, cluster ID and token work together. A 401 or 403 means the token or cluster is wrong; say so and keep the old settings. Ruru needs no change for this.

5. **[P2] After a committed handback, the new owner gives up if the old lease is still held.**

   [ClusterCoordinator.swift:2837](../Sources/SwiftBot/ClusterCoordinator.swift#L2837), Ruru [LeaseStore.swift:72](../../ruru/Sources/WitnessKit/LeaseStore.swift#L72).

   The old owner releases its lease during commit, but `release` is a best-effort request whose result is ignored. If it doesn't arrive, Ruru keeps the lease for up to 30 seconds and refuses the returning Mac (`ownership_held`). `promoteToLeader` records "Takeover blocked" and stays passive. The old owner has already demoted, so nobody owns the bot until the returning Mac's health monitor promotes it about a minute later.

   Fix: after a committed handback, keep retrying `acquire` for up to about 35 seconds (one lease plus margin) when the refusal is `ownership_held`. This depends on the error codes from finding 1.

6. **[P3] Ruru can't list a Failover that has never owned the lease.**

   Ruru's Known Servers come only from ownership history, so making the Failover the Preferred Primary means typing its node ID. Ruru also can't show whether the Standby is alive.

   Change in both repos: SwiftBot adds its optional `nodeID` and `nodeName` to the policy request it already sends every 5 seconds. Ruru records "last seen" per participant for display only, and offers those nodes in Choose Primary. The route stays read-only for ownership. Older clients that omit the fields keep working.

## What needs to change in Ruru

- **Required for 2.0:** nothing. Ruru's protocol already returns the error codes SwiftBot needs for findings 1 and 5, and the policy route needed for finding 4.
- **Recommended:** a pause warning before installing an update with a live lease (finding 2).
- **Your call:** same-boot lease continuity (finding 2), and participant last-seen through policy reads (finding 6).

## Live drill plan

Run with matching SwiftBot builds on both Macs, Ruru ready, and the bot preferably on a test token or in a quiet period. JohnStudio runs the live bot, so decide deliberately before putting a test build on it. During each drill, watch Ruru's Activity for the service: there must never be two owners, and terms must only increase.

| # | Drill | Expected before the fixes | Expected now (findings 1–3 fixed) |
|---|---|---|---|
| A | Baseline: Primary running, Ruru Ready | Ruru shows the Primary's node ID as owner; the Failover shows Ready and a dashed line | Same |
| B | Quit SwiftBot on the Primary | Failover promotes in about 60–75 s with term +1; the bot replies once from the Failover | Same |
| C | Restart the Primary | Starts passive, catches up, takes back after 60 s healthy; one owner throughout | Same |
| D | Cut the Primary ↔ Failover link only (both still reach Ruru) | Failover's acquire is refused ("exclusive ownership unavailable"); the Primary keeps the bot | Same. This is the drill Ruru exists for |
| E | Cut the Primary ↔ Ruru link only, for example by blocking the hostname in `/etc/hosts` | Primary demotes on its first failed renewal; the Failover takes over after about a minute | Primary keeps output until its deadline (≤28 s), then stops; the Failover acquires once the lease expires |
| F | Quit and relaunch Ruru | Forced failover and handback (finding 2) | About 30–40 s pause; same owner, new term |
| G | Stop Ruru for 2 minutes with the Failover also off | Bot stays offline after Ruru returns (finding 1) | Bot pauses, then recovers by itself |
| H | In Ruru, set the Failover as Preferred Primary, then clear it | Failover takes over through handback after the delay; clearing returns the bot to the configured Primary | Same |
| I | Rule with a 2-minute delay and a webhook step: trigger it, then quit the Primary | The Failover sends once at the due time, and the webhook URL resolves on the Failover | Same |
| J | Kill the returning Mac during handback catchup | Owner unfreezes within 90 s and keeps the bot | Same |
| K | Configure Ruru on the Primary only, then run drill D | Failover may promote without a lease: **two owners** (finding 3) | Failover refuses and shows a configuration mismatch |

Run K only with a test token. Today it is expected to produce two owners.

## Validation of the fixes

Debug build and the complete Debug test suite: **877 tests, 0 failures** on DevMini (twice). Repeating the mesh suites with `-test-iterations` shows the two-node handback tests failing about 1 run in 15, on the earlier code too. The returning node sometimes never registers with the owner in the test harness. That is tracked separately; it is not a failure of these fixes. None of the drills above have been run on real Macs.
