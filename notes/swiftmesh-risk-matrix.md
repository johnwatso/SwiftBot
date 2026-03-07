# SwiftMesh Risk Matrix

**Generated:** 2026-03-08
**Authors:** Claude, Codex, Gemini, Kimi (agent team discussion)
**Status:** Draft — awaiting John's review
**Related:** `notes/swiftmesh-plan.md`, `RISK_MATRIX.md`

---

## Risk Matrix

| # | Area | Risk | Likelihood | Impact | Priority | Current Controls | Recommended Fix |
|---|------|------|:---:|:---:|:---:|---|---|
| 1 | **Discovery** | Service type mismatch — nodes advertise `_swiftbot-mesh._tcp` but plan targets `_swiftmesh._tcp`. Mixed-version clusters partition silently: each side looks healthy in isolation. | High | High | P1 | None | Browse both `_swiftmesh._tcp` and `_swiftbot-mesh._tcp` during migration; advertise new type as primary. |
| 2 | **Startup** | Race condition — `pollClusterStatus()` fires immediately when `SwiftMeshView` appears, but `NWListener` starts asynchronously (~100ms gap). Requests fail silently during that window. | High | High | P1 | None | Gate initial poll on `handleListenerState(.ready)` signal before attempting any cluster communication. |
| 3 | **Listener Readiness** | Worker registers with leader before its own listener is fully `.ready`. Leader stores the registration and then fails callback/sync/probe traffic against a port that isn't listening yet. | High | High | P1 | None | Require listener `.ready` before initiating registration, or implement a callback-verified ACK loop on the leader side. |
| 4 | **Promotion Safety** | False-positive promotion — 3 consecutive health misses trigger standby promotion. A transient network partition can cause both nodes to promote simultaneously (split-brain). | Medium | High | P2 | Stale `leaderTerm` rejection prevents divergent writes post-split. | Require witness confirmation: promote only if 1+ additional peers also see the leader as unreachable. |
| 5 | **Port Normalization** | `normalizedBaseURL` treats `:80`/`:443` differently from the configured mesh port. Tests, runtime, and docs are out of alignment on the canonical policy. | High | High | P2 | HMAC auth prevents malformed requests from being accepted. | Decide canonical policy; align `ClusterCoordinator`, all tests, and docs in one pass. *(Tracked in main RISK_MATRIX.md)* |
| 6 | **Sync Reliability** | Failed sync replication to standby nodes is silently dropped (`// best effort` comments). No retry mechanism exists; standby state diverges without any signal. | Medium | High | P3 | Cursor-based incremental sync allows eventual catch-up on reconnect. | Add a retry queue with exponential backoff for failed replication attempts. |
| 7 | **Registration Storms** | Worker registration retries every 4s regardless of failure reason. A recovering leader receives a burst of simultaneous registration requests, potentially destabilizing recovery. | Medium | Medium | P3 | None | Add exponential backoff with jitter for registration retry failures. |
| 8 | **Graceful Shutdown** | Nodes that stop cleanly do not notify peers. Workers appear as "disconnected" only after a 20s stale timeout, leaving the cluster map stale during intentional restarts. | Medium | Medium | P4 | Stale timeout eventually cleans up disconnected entries. | Implement a `/cluster/leave` endpoint; call it on clean shutdown before terminating the listener. |
| 9 | **Discovery Health** | `discoveredPeerBaseURLs()` returns peers without verifying reachability. Stale or unreachable peers are handed to the connection layer, causing unnecessary failures. | Medium | Low | P4 | None | Add a lightweight reachability probe before returning discovered peers. |
| 10 | **Test Port Conflicts** | All mesh tests bind to hardcoded ports (39100–39205). If any port is in use from a prior failed run or in CI, tests fail non-deterministically. | High | Medium | P4 | None | Switch to port 0 (OS-assigned) and read back the assigned port from the bound listener. |
| 11 | **UI Diagnosability** | Cluster failures surface as generic "Disconnected" states. No reason codes are shown for `401/403`, bad port normalization, callback refusal, or standby-server-inactive scenarios. | High | Medium | P4 | None | Backend emits machine-readable reason codes (`auth_failed`, `listener_not_ready`, `leader_unreachable`, `stale_term_rejected`, `callback_probe_failed`, `service_discovery_mismatch`); UI maps these to human-readable messages. |
| 12 | **UI Topology Visibility** | No topology visualization exists. Users cannot see which node is leader vs. standby, peer health, or current `leaderTerm` without reading logs. | Medium | Medium | P5 | `SwiftMeshView` shows node list but no health indicators or role distinction in compact map view. | Add a dedicated Cluster Topology view: leader/standby badges, per-peer health (green/yellow/red), current term display. |
| 13 | **Configuration Guardrails** | No validation prevents enabling mesh without a shared secret or with an invalid port. Misconfiguration results in silent auth failure rather than a clear setup error. | Low | Medium | P5 | None | Validate shared secret presence and port format before applying mesh settings; block enable with actionable error if invalid. |
| 14 | **Manual Peer Fallback** | Bonjour discovery is the only connection path in the UI. Networks that block mDNS (VPNs, managed Wi-Fi) leave users with no way to connect nodes. | Low | Medium | P5 | Static peer list exists in settings but is not surfaced prominently. | Surface the static peer list as a prominent "Manual Connection" input with clear instructions. |

---

## Priority Summary

| Priority | Items | Description |
|----------|-------|-------------|
| **P1** | #1, #2, #3 | Blocking — mesh will not reliably form without these fixes |
| **P2** | #4, #5 | Safety — split-brain risk and protocol contract alignment |
| **P3** | #6, #7 | Reliability — silent divergence and registration storm under load |
| **P4** | #8, #9, #10, #11 | Hygiene — shutdown, discovery, test stability, and error visibility |
| **P5** | #12, #13, #14 | Polish — UI topology, config guardrails, manual fallback |

---

## Ownership

| Agent | Scope |
|-------|-------|
| **codex** | P1 listener readiness (#2, #3), service type migration (#1), protocol strictness |
| **claude** | Architecture alignment — port normalization policy (#5), promotion safety design (#4) |
| **gemini** | UI diagnosability (#11), topology view (#12), configuration guardrails (#13, #14) |
| **kimi** | Test port conflicts (#10), sync reliability verification (#6), QA on all fixes |

---

*Synthesized from agent team discussion in #general, 2026-03-08. Update ownership and status as work progresses.*
