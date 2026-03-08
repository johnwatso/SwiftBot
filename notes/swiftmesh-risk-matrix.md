# SwiftMesh — Improvement Plan

**Generated:** 2026-03-08
**Authors:** Claude, Codex, Gemini, Kimi (agent team discussion)
**Status:** Draft — refreshed against current code on 2026-03-08
**Related:** `notes/swiftmesh-plan.md`, `notes/swiftmesh-observed-behavior.md`, `RISK_MATRIX.md`

This document tracks areas where SwiftMesh can be made better — new capabilities, reliability improvements, UX enhancements, and fixes. Risks are flagged inline where relevant.

---

## Current Code Audit

Verified against the current repository state on 2026-03-08:

- `ClusterCoordinator` still advertises and browses only `_swiftbot-mesh._tcp`; mixed-version discovery compatibility is not implemented yet.
- `AppModel.applyClusterSettingsRuntime()` still calls `pollClusterStatus()` immediately after `cluster.applySettings()`, while listener readiness is only reported later through `handleListenerState(.ready)`.
- `restartWorkerRegistrationIfNeeded()` still starts the registration loop immediately after startup, and `registerWithLeader()` does not wait for local listener readiness before advertising `baseURL`.
- `syncToNode(...)` still treats replication as `// best effort`, and incremental conversation sync still drops failed deliveries without a retry queue.
- `discoveredPeerBaseURLs()` still returns Bonjour results directly without probing reachability before those peers are handed to connection logic.

---

## Improvement Areas

| # | Area | What to Improve | Type | Priority | Owner | Status | Risk if Not Addressed |
| :- | :--- | :--- | :---: | :---: | :--- | :--- | :--- |
| 1 | **Discovery** | Browse both `_swiftmesh._tcp` and `_swiftbot-mesh._tcp` during the migration period, and advertise the new type as primary. The live coordinator still advertises and browses only `_swiftbot-mesh._tcp`. | Fix | P1 | codex | Open | Nodes on different versions cannot see each other. |
| 2 | **Startup Sequencing** | Gate the first cluster poll on `handleListenerState(.ready)` before attempting any network contact. `AppModel.applyClusterSettingsRuntime()` currently polls immediately after `cluster.applySettings()`, before listener readiness is confirmed asynchronously. | Fix | P1 | codex | Open | Silent failures on startup; unreliable initial cluster state. |
| 3 | **Listener Readiness on Register** | Require a node's own listener to be fully `.ready` before registering with the leader, or implement a callback-verified ACK loop. The current registration loop starts immediately after startup and can advertise a node before it is actually accepting callbacks. | Fix | P1 | codex | Open | Leader stores peer but cannot reach it; "registered but not participating" behavior. |
| 4 | **Port Normalization** | Decide and document the canonical port-normalization policy, then align `ClusterCoordinator`, all tests, and docs in a single pass. | Fix | P2 | claude | Open | Tests and runtime disagree; hard to reason about URL handling. |
| 5 | **Promotion Safety** | Add a witness requirement to standby promotion: only promote after 1+ other peers also confirm the leader is unreachable. Prevents false-positive split-brain during transient partitions. | Improvement | P2 | claude | Open | Two nodes promote simultaneously, causing a split-brain. |
| 6 | **Sync Reliability** | Replace the current `// best effort` sync drops with a retry queue and exponential backoff for replication failures. `syncToNode(...)` still swallows failures, and incremental conversation pushes still fail once and stop. | Improvement | P3 | codex | Open | Standby diverges silently; data loss for conversation history during failover. |
| 7 | **Registration Backoff** | Add exponential backoff with jitter to worker registration retries. The current retry interval is still a fixed 4 seconds for every standby/worker. | Improvement | P3 | codex | Open | Recovering leader overwhelmed by simultaneous registration storm. |
| 8 | **Actionable Error Codes** | Emit machine-readable reason codes from the cluster layer (`auth_failed`, `listener_not_ready`, `leader_unreachable`, `stale_term_rejected`, `callback_probe_failed`, `service_discovery_mismatch`) and map them to clear UI messages. | Improvement | P3 | gemini | Open | Users see generic "Disconnected" with no way to self-diagnose. |
| 9 | **Graceful Shutdown** | Add a `/cluster/leave` endpoint and call it on clean shutdown before listener teardown, so peers know immediately rather than waiting 20s for a stale timeout. | Improvement | P4 | codex | Open | Cluster map shows stale "disconnected" state for 20s after intentional exits. |
| 10 | **Discovery Health Check** | Probe peer reachability before returning URLs from `discoveredPeerBaseURLs()`. The current discovery path returns Bonjour results directly without filtering stale or unreachable peers first. | Improvement | P4 | codex | Open | Unnecessary connection failures against stale discovered peers. |
| 11 | **Manual Peer Fallback UI** | Surface the static peer list as a prominent "Manual Connection" field in the mesh UI, with clear instructions for networks that block mDNS (VPNs, managed Wi-Fi). | Improvement | P4 | gemini | Open | Users on restricted networks have no way to connect nodes. |
| 12 | **Topology Visualization** | Add a Cluster Topology view showing leader/standby badges, per-peer health indicators (green/yellow/red), and the current `leaderTerm`. | Improvement | P4 | gemini | Open | Users cannot assess cluster health without reading logs. |
| 13 | **Test Port Stability** | Replace hardcoded test ports (39100–39205) with port 0 (OS-assigned) across all mesh tests. | Fix | P4 | kimi | Open | Flaky CI failures when ports are already in use from prior runs. |
| 14 | **Integration Tests** | Add `MeshIntegrationTests.swift` covering multi-node startup sequences, failover, partition, and delta-replay recovery scenarios. | Improvement | P4 | kimi | Open | Multi-node regressions only caught manually or in production. |
| 15 | **Configuration Guardrails** | Validate shared secret presence and port format before applying mesh settings; block enable with an actionable error if configuration is incomplete. | Improvement | P5 | gemini | Open | Silent auth failures when users enable mesh without a shared secret. |

---

## Priority Summary

| Priority | Items | Theme |
|----------|-------|-------|
| **P1** | #1, #2, #3 | Mesh won't reliably form without these |
| **P2** | #4, #5 | Protocol correctness and split-brain safety |
| **P3** | #6, #7, #8 | Reliability under load and diagnosability |
| **P4** | #9–#14 | Hygiene, visibility, and test robustness |
| **P5** | #15 | UX polish and setup guardrails |

---

*Generated from agent team discussion in #general, 2026-03-08. Update Status as work progresses.*
