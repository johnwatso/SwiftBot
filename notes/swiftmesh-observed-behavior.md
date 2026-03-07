# SwiftMesh Stabilization — Observed vs. Expected Behavior (March 2026)

This document provides a research-driven matrix of the current bugs breaking SwiftMesh functionality and the required fixes to achieve immediate stability.

## 1. Stabilization Matrix

| Component | Observed Behavior (Broken) | Expected Behavior (Fixed) | Priority |
|-----------|----------------------------|---------------------------|----------|
| **Auth Headers** | `AppModel+Gateway.swift` uses `X-Cluster-Secret` for resync. `ClusterCoordinator.swift` expects HMAC signature (`X-Mesh-Signature`). | All mesh-to-mesh calls (including resync) must use `applyMeshAuth` for HMAC signatures. | **P0 (Fixed 2026-03-07)** |
| **Resync Auth** | `requestResyncFromLeader` (AppModel) sends plain secret; Leader returns 401 Unauthorized. Error is swallowed (silently fails). | Standby successfully authenticates and receives paginated conversation history. | **P0 (Fixed 2026-03-07)** |
| **Split-Brain** | `handleMeshConversationSync` and `handleMeshWorkerRegistrySync` ignore `leaderTerm`. Stale leaders can overwrite state. | All sync handlers MUST validate `payload.leaderTerm >= currentLeaderTerm` before applying. | **P0 (Fixed 2026-03-07)** |
| **Replication** | `updateReplicationCursor` does not check for progress. Cursors can move backwards if messages are re-delivered or stale. | Cursors must only move forward (monotonicity check on term and record ID). | **P1 (Fixed 2026-03-07)** |
| **Standby Connectivity** | Standby nodes were hardcoded to NOT start a server or register with the leader. | Standby starts listener and registers with leader to receive sync pushes. | **P0 (Fixed 2026-03-07)** |
| **Auth Window** | 300s skew window in `verifyMeshAuth` is unnecessarily loose for a local mesh. | Tightened to 60s skew window with frequent nonce pruning. (Implemented 2026-03-07) | **P1 (Done)** |
| **Handshake** | `handleWorkerRegistration` is unauthenticated. `performWorkerConnectionTest` (Test Button) uses `GET /cluster/ping` without HMAC. | Use signed `POST /v1/mesh/register`. Leader returns signed ACK. Test Button must use HMAC to verify bidirectional sight. | **P0 (Fixed 2026-03-07)** |
| **Code Hygiene** | Production methods mixed with `test*` helpers and `#if DEBUG` overrides. | All test logic isolated to `ClusterCoordinator+Testing.swift` and `TestSupport.swift`. (Implemented 2026-03-07) | **P1 (Done)** |

## 2. Reproduction Steps (Split-Brain Scenario)

1. Start Node A (Primary, Term 1) and Node B (Standby, Term 1).
2. Kill Node A.
3. Node B promotes to Primary (Term 2).
4. Restart Node A (it still thinks it is Primary, Term 1).
5. **Observed (Bug):** Node A sends a sync payload (Term 1) to Node B. Node B accepts it and overwrites its Term 2 state with Term 1 stale data.
6. **Expected:** Node B rejects the Term 1 payload from Node A because `1 < 2`. Node A eventually receives a heartbeat from Node B (Term 2) and steps down to Standby.

## 3. Log Evidence (Auth Mismatch)

When `requestResyncFromLeader` is triggered:
- **Leader Logs:** `meshLogger.warning("Mesh auth rejected: missing required headers")` (due to missing HMAC headers).
- **Standby Logs:** No error (the `URLSession` response code 401 is not checked or surfaced).

## 4. Current Networking Contract (Updated 2026-03-07)

- Internet peer hosts are supported (not LAN-only).
- Unsafe endpoints remain blocked (wildcard/metadata targets).
- Mesh URL normalization defaults missing ports to configured mesh port (`clusterListenPort`, default `38787`), not implicit `80/443`.
- `/cluster/status` signing and verification now use the same path for HMAC.
- Startup leader reconciliation prevents returning-primary split brain by demoting to standby when an active leader is reachable.
- Leader registration now prefers observed source host + declared listen port for callback address storage.

---
**Documented by:** Gemini (Research & Documentation)  
**Date:** 2026-03-07
