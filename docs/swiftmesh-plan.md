# SwiftMesh Stabilization Plan

**Status:** Pending approval
**Authors:** Claude + Codex (AI agents)
**Review requested from:** John
**Date:** 2026-03-07

---

## 1. Code Review Findings

Review of `SwiftMeshView.swift`, `ClusterCoordinator.swift`, and all Mesh test files.

### SwiftMeshView.swift

| # | Severity | Finding |
|---|----------|---------|
| 1 | Low | `connectedNodeCount` and `topologyNodes` are redundant pass-through computed properties — both just return `app.clusterNodes` unchanged. `ClusterMapView.connectedNodes` has the same issue. These add indirection with no value. |
| 2 | Low | `HeartbeatConnectionView.pulseStep` is declared as `var` but returns a constant literal (`0.035`). Should be a `let`. |
| 3 | Medium | `TimelineView(.periodic(from: .now, by: 0.035))` fires ~28 times/second **per connection line**. With N workers this creates N independent high-frequency redraws. A single shared clock driving all pulse animations would be significantly more efficient at scale. |
| 4 | Medium | `SwiftMeshHardwareIcons` "mac" catch-all prefix returns a Mac Studio icon for any model that starts with "mac" but isn't Mini/Air/Pro. A plain "MacBook" (no Pro/Air suffix) normalizes to "macbook", matches the "mac" catch-all, and receives the wrong icon (`macStudioName`). |
| 5 | Low | `mapHeight` step function caps at 680px for 7+ workers. With 10–12 nodes in circular layout, cards risk overlap or clipping. |
| 6 | Low | Disconnected nodes are dimmed (opacity 0.58) in `NodeDetailCard` but **not** in compact `ClusterNodeView` used in the Cluster Map. Disconnected workers appear identical to healthy ones in the map. |

### Test Files

| # | Severity | Finding |
|---|----------|---------|
| 7 | Medium | `testSelfIsExcludedFromDiscovery` in `MeshDiscoveryTests` is misleadingly named. It uses `testInjectDiscoveredPeers`, which bypasses the self-filter in `handleDiscoveryResults`. The test only validates state reflection. Should be renamed to reflect what it actually tests. |
| 8 | Low | Test comments in `MeshDiscoveryTests` are numbered 1, 2, 3, 5 — no test 4. A deleted test was never renumbered. |
| 9 | Medium | `makeRequest` in `MeshFailoverTests` and `makeHTTPRequest` in `MeshSyncTests` are functionally identical helpers duplicated across both files. Should be extracted to a shared test utility to prevent drift. |
| 10 | High | All Mesh tests bind to hardcoded localhost ports (39100–39205). If any port is in use from a prior failed run or in CI, tests fail non-deterministically. Tests should use port 0 (OS-assigned) and read back the assigned port. |

---

## 2. Architecture Baseline

Agreed between Claude and Codex. Awaiting John's formal approval before implementation begins.

### Roles

```
discovering → standby
           → leader
```

`standalone` and `worker` modes are out of scope for this stabilization effort.

### Startup Flow

1. Node starts in `discovering`.
2. If a persisted `lastKnownLeaderAddress` exists, attempt contact immediately — exit discovery early on confirmed reachability.
3. Otherwise, run peer discovery for up to 8 seconds (Bonjour `_swiftmesh._tcp` + optional static peer list).
4. If a reachable leader is found → become `standby`.
5. If peers exist but no leader → wait briefly, then elect.
6. If no peers → become `leader`.
7. **No promotion may occur during the discovery window.**

> **Note on service discovery:** The current codebase advertises `_swiftbot-mesh._tcp`. During migration, nodes should browse both `_swiftmesh._tcp` and `_swiftbot-mesh._tcp`, and advertise the new primary. This avoids partitioning mixed-version clusters.

### Leader Rules

- Only `role == .leader` may open a connection to `wss://gateway.discord.gg`.
- `DiscordService` must check cluster role before connecting; block if not leader.
- Leader sends cluster heartbeat every ~2 seconds.
- Standby monitors heartbeat; promotes after **3 consecutive misses**.

### Promotion Safety

```
term += 1          // strictly monotonic, resets sequence to 0
persist term
leaderID = nodeID
role = .leader
```

A returning node that finds a higher term in the cluster must step down to `standby`.

### Event Ordering

Leader assigns a `sequence: Int64` to every committed event:
- Sequence is **strictly monotonic within a term** and **resets to 0 on each new term**.
- Replicas apply events ordered by `(term, sequence)` only.
- `id: UUID` is the idempotency key (dedup on replay/retry).
- `timestamp: Date` is metadata only — never used for ordering.

### MeshEvent Model

```swift
struct MeshEvent {
    let id: UUID
    let term: Int
    let sequence: Int64
    let timestamp: Date
    let type: MeshEventType
    let payload: Data
}

enum MeshEventType {
    case ruleCreated
    case ruleUpdated
    case ruleDeleted
    case settingsUpdated
    case patchyTargetChanged
}
```

### Write Path

```
Admin UI → local node
    ↓
submitChange()
    ↓ (if standby: forward to leader)
Leader commits event → assigns (term, sequence)
    ↓
Leader replicates to peers
    ↓
Peers apply in (term, sequence) order, persist state
```

Standby nodes **must forward writes** to the leader rather than applying locally.

### `submitChange()` Result Contract

```swift
enum SubmitChangeResult {
    case accepted(appliedTerm: Int, sequence: Int64)
    case redirectedToLeader(leaderID: String, leaderAddress: String, term: Int)
    case rejectedStaleTerm(currentTerm: Int, currentLeaderID: String, redirectHint: String?)
}
```

`redirectHint` in `rejectedStaleTerm` allows callers to retry against the current leader without a separate discovery step.

### Persistence Schema

**File:** `~/Library/Application Support/SwiftBot/cluster_state.json`

```json
{
  "nodeID": "string",
  "term": 0,
  "lastKnownLeaderID": "string",
  "lastKnownLeaderAddress": "string",
  "lastAppliedTerm": 0,
  "lastAppliedSequence": 0
}
```

`lastKnownLeaderAddress` enables fast startup reconnection.
`lastAppliedTerm` + `lastAppliedSequence` provide a precise cursor for delta replay on rejoin.

### Discovery

- **Bonjour:** `_swiftmesh._tcp` (browse `_swiftbot-mesh._tcp` during migration)
- **Static:** Configured peer list in Settings (allows early exit without full Bonjour timeout)

### Acceptance Gates

Before shipping, all of these must pass:

| Gate | Description |
|------|-------------|
| Gatekeeper | Non-leader node cannot open Discord gateway connection |
| Failover | Leader loss → standby promotes after threshold, term increments, old leader rejoins as standby |
| State convergence | Same ordered MeshEvent log on a 3-node cluster after concurrent admin edits |
| Recovery | Offline node rejoins and fully converges via delta replay from `(lastAppliedTerm, lastAppliedSequence)` |

---

## 3. Phase Plan

### Phase 0 — Spec Freeze
**Goal:** Lock all contracts and acceptance criteria before any code changes.

- [ ] John approves architecture baseline (this document)
- [ ] Event ordering contract confirmed: `(term, sequence)`, sequence resets per term
- [ ] `submitChange()` result enum agreed: `accepted | redirectedToLeader | rejectedStaleTerm`
- [ ] Persistence schema v1 fields confirmed
- [ ] Acceptance gate test matrix signed off (gatekeeper, failover, convergence, recovery)
- [ ] Codex and Claude confirm no open questions

**Exit criteria:** This document is marked "Approved" by John. No implementation begins before this gate.

---

### Phase 1 — Foundation
**Goal:** Block gateway on non-leaders, introduce `discovering` role, establish persistence.

- [ ] Add `discovering` to `ClusterMode` enum
- [ ] Prevent any promotion or gateway connection during discovery window
- [ ] Gate Discord gateway connection behind `role == .leader` in `DiscordService`
- [ ] Implement `cluster_state.json` persistence: `nodeID`, `term`, `lastKnownLeaderID`, `lastKnownLeaderAddress`
- [ ] Load persisted state on startup; attempt early-exit discovery via `lastKnownLeaderAddress`
- [ ] Handle legacy role mapping (`standalone/worker` → deterministic new role) for settings migration

**Exit criteria:** Node correctly enters `discovering`, respects gateway gate, persists and restores term across restarts.

---

### Phase 2 — Stable Leader Election
**Goal:** Reliable 2-node cluster with safe failover.

- [ ] Implement `discovering → leader` path (timeout, no peers, or no leader found)
- [ ] Implement `discovering → standby` path (reachable leader confirmed)
- [ ] Leader heartbeat broadcast (~2s interval)
- [ ] Standby monitors heartbeat; promotes after 3 misses; increments + persists term
- [ ] Returning node compares terms; steps down if higher term exists in cluster
- [ ] Browse both `_swiftmesh._tcp` and `_swiftbot-mesh._tcp` during discovery

**Exit criteria:** 2-node cluster reliably elects leader, survives leader kill, promotes standby, old leader rejoins correctly.

---

### Phase 3 — Leader-Only Writes + MeshEvent Replication
**Goal:** All state changes go through the leader and replicate to peers.

- [ ] Define `MeshEvent` struct with `id`, `term`, `sequence`, `type`, `payload`
- [ ] Implement `submitChange()` with result contract (`accepted | redirectedToLeader | rejectedStaleTerm`)
- [ ] Standby forwards writes to leader; returns redirect result to caller
- [ ] Leader commits event to log, assigns `(term, sequence)`, replicates to peers
- [ ] Peers apply events in `(term, sequence)` order; persist `lastAppliedTerm` + `lastAppliedSequence`
- [ ] Implement event types: `ruleCreated`, `ruleUpdated`, `ruleDeleted`, `settingsUpdated`, `patchyTargetChanged`

**Exit criteria:** Admin edit on standby node correctly applies on all nodes in order with no divergence.

---

### Phase 4 — Rejoin and Convergence
**Goal:** Offline nodes catch up automatically on reconnect.

- [ ] On connect/reconnect, node sends `(lastAppliedTerm, lastAppliedSequence)` to leader
- [ ] Leader returns paginated delta from that cursor
- [ ] Rejoining node replays delta and catches up before serving reads
- [ ] Handle term mismatch on rejoin (full resync if prior term too old)
- [ ] (Deferred) Snapshot path: leader sends full state if delta is too large

**Exit criteria:** Node offline for an extended period rejoins and converges without manual intervention.

---

### Phase 5 — Hardening and Tests
**Goal:** All acceptance gates pass; test reliability improved.

- [ ] Gatekeeper test: non-leader cannot open gateway (automated)
- [ ] Failover test: 3-miss promotion, term increment, old leader rejoins as standby
- [ ] State convergence test: same ordered event log on 3-node cluster after concurrent edits
- [ ] Recovery test: offline node rejoins and converges via delta replay
- [ ] Fix hardcoded test ports (39100–39205) → use port 0 (OS-assigned)
- [ ] Rename `testSelfIsExcludedFromDiscovery` to reflect actual behavior
- [ ] Extract duplicated `makeRequest`/`makeHTTPRequest` helpers into shared test utility
- [ ] Renumber `MeshDiscoveryTests` (currently 1, 2, 3, 5 — missing 4)

**Exit criteria:** All 4 acceptance gates pass; no flaky test failures in CI.

---

## 4. Non-Goals (This Iteration)

- Worker mode
- Multi-leader or split-brain resolution
- Distributed consensus algorithms (Raft, Paxos)
- More than 3 nodes in primary test scenarios

---

## 5. Open Questions

None — all spec decisions are locked. See architecture baseline above.

---

*Document generated from agent discussion in #general (messages 984–1005). Update this file as implementation progresses.*
