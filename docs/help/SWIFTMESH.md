<p align="center">
  <img src="../../assets/readme/app-icon.png" width="100" alt="SwiftBot icon">
</p>

<h1 align="center">SwiftMesh</h1>

This guide covers **SwiftMesh** — SwiftBot's failover and worker-offload clustering layer. It walks through the roles, the Join Code pairing flow, and exactly what (if any) networking has to be opened up.

1. [What SwiftMesh is](#1-what-swiftmesh-is)
2. [Roles](#2-roles)
3. [Network topology — what to forward](#3-network-topology--what-to-forward)
4. [macOS firewall](#4-macos-firewall)
5. [Pairing with a Join Code](#5-pairing-with-a-join-code)
6. [Rotating the shared secret](#6-rotating-the-shared-secret)
7. [What the Failover sees in real time](#7-what-the-failover-sees-in-real-time)
8. [How failover detection works](#8-how-failover-detection-works)
9. [Handover Test — rehearse without an outage](#9-handover-test--rehearse-without-an-outage)
10. [Worker offload](#10-worker-offload)
11. [Auto-reclaim after failover](#11-auto-reclaim-after-failover)
12. [The `/live` endpoint (monitoring + failover signal)](#12-the-live-endpoint-monitoring--failover-signal)
13. [Cloudflare tunnel resilience](#13-cloudflare-tunnel-resilience)
14. [Troubleshooting](#14-troubleshooting)

All addresses and ports are **examples**. The default listen port is `38787` — change it under **Settings → SwiftMesh → Listen Port** if it clashes with something else on your network.

---

## 1. What SwiftMesh is

SwiftMesh lets you run more than one SwiftBot node and treat them as one logical bot. Two main use cases:

- **Failover** — a Standby node sits idle, watching the Primary. If the Primary disappears, the Standby promotes itself and the bot keeps running.
- **Worker offload** — a Primary delegates expensive jobs (AI replies, wiki lookups) to one or more Workers, freeing the Primary's main loop for gateway traffic.

Both setups use the same connection model and the same Join Code pairing flow.

---

## 2. Roles

| Role | What it does | When to use |
| --- | --- | --- |
| **Standalone** | Single node, no clustering. | Default for one-Mac installs. |
| **Primary** *(Leader)* | Owns the Discord gateway connection and accepts inbound SwiftMesh connections from Standbys / Workers. | The "main" SwiftBot instance. |
| **Fail Over** *(Standby)* | Connects out to the Primary, mirrors state, takes over if the Primary fails. | Second Mac on the same LAN or across the internet. |
| **Worker** *(deprecated)* | Connects out to the Primary and runs offloaded jobs. | Existing setups only; prefer Fail Over for new installs. |

Role is configured under **Settings → SwiftMesh → Role** on each node.

---

## 3. Network topology — what to forward

SwiftMesh is a one-way connect: **the Standby/Worker opens an outbound TCP connection to the Primary's listen port.** All subsequent traffic (state sync, jobs, heartbeats) flows back and forth over that single socket.

That means port forwarding is **only ever needed on the Primary's side**, and only if the Standby is off-LAN.

| Topology | Primary forwarding | Standby forwarding |
| --- | --- | --- |
| Both on the same LAN | ❌ None | ❌ None |
| Primary at home, Standby at the office | ✅ Forward `38787/TCP` on Primary's router → Primary Mac | ❌ None |
| Primary on a VPS with a public IP | ❌ None (already public) | ❌ None |

Why nothing on the Standby side: every consumer NAT allows arbitrary outbound TCP. The Standby is the **client** in the connection — it dials out, the router opens a return path automatically.

The Join Code embeds **all** of the Primary's reachable IPs at copy time (every LAN interface plus the public WAN IP from a public-IP lookup) and the listen port. The Standby tries each address in order and persists the one that connects, so a single Join Code works whether the Standby is on the same LAN or off-network.

> **Tip** — if you only ever need failover within the house, you don't need any router config. Skip the public IP / port forwarding entirely.

---

## 4. macOS firewall

The first time SwiftBot starts in Primary mode, macOS will prompt:

> *"Do you want the application 'SwiftBot' to accept incoming network connections?"*

Click **Allow**. If you dismissed it by accident:

1. Open **System Settings → Network → Firewall → Options…**
2. Find **SwiftBot** in the list and set it to **Allow incoming connections**.

No firewall change is needed on Standby/Worker Macs — they only make outbound connections.

---

## 5. Pairing with a Join Code

The Join Code is a single `swiftmesh://join?b=…` URL containing the Primary's reachable addresses, listen port, and the cluster shared secret. **Treat it as a bearer credential** — anyone with the code can join the mesh until you rotate the secret.

### On the Primary

You can generate the Join Code from either surface:

- **macOS app** — **Settings → SwiftMesh → SwiftMesh Join Code → Copy SwiftMesh Join Code**.
- **WebUI** — **SwiftMesh** tab → *Pairing — Add a Node* panel → **Copy Join Code** or **Open in SwiftBot**.

Both surfaces generate the code on demand (nothing is cached) and write it to the clipboard or launch the `swiftmesh://` handler. The WebUI panel is admin-only and audit-logged.

### On the Standby

Three ways to apply a Join Code, depending on where you are:

| You are… | Use |
| --- | --- |
| In front of the Standby Mac, code on clipboard | **Onboarding → Set Up SwiftMesh → Paste & Connect**, *or* **Settings → SwiftMesh → Paste & Verify Join Code** |
| Logged into the **Primary's** WebUI from the Standby's browser | **SwiftMesh tab → Open in SwiftBot** — launches the Standby's SwiftBot app via `swiftmesh://` |
| Wherever — passing the code around | Drop the `swiftmesh://join?b=…` link into a note/message; opening it on the Standby Mac triggers the same flow |

In all three cases the Standby:

1. Decodes the Join Code.
2. Tries each address in the bundle in order (LAN first, then WAN).
3. Persists the first address that connects as the Primary host.
4. Shows a green tick and auto-continues to the dashboard after 10 seconds (mid-onboarding) or after you click **Join Cluster** (post-onboarding confirmation sheet).

### Why post-onboarding pops a confirmation sheet

If onboarding has already been completed and a `swiftmesh://` link is opened, SwiftBot shows a confirmation sheet listing the Primary host(s), port, and a masked secret before applying. This is deliberate: without the confirmation, a malicious link could silently repoint an existing node to an attacker's "Primary".

During onboarding, no sheet is needed — the user is already setting the node up, so the link is auto-applied into the SwiftMesh setup step.

---

## 6. Rotating the shared secret

If you suspect a Join Code has leaked, or you just want to invalidate everything previously distributed:

1. **Settings → SwiftMesh → SwiftMesh Join Code → Rotate Shared Secret**.
2. Confirm the prompt.

Effects:

- A fresh shared secret is generated and saved.
- Every previously issued Join Code stops working immediately.
- Connected Standbys/Workers will lose authentication on their next handshake and need to re-pair using a freshly generated code.

Rotation lives in the macOS app only (not the WebUI) to keep it behind the local-machine trust boundary.

---

## 7. What the Failover sees in real time

A Failover node should not feel like a dead stand-in. SwiftMesh continuously pushes a **live snapshot** from the Primary so the Failover's dashboard mirrors the Primary's view:

| Pushed every sync tick | Why |
| --- | --- |
| Bot username, discriminator, avatar hash | Sidebar shows the real bot identity, not a placeholder |
| Connected server list (id → name) | Server count + names match the Primary |
| Gateway event counters (ready, guildCreate, voiceState, total) | Activity widgets show real numbers |
| Last gateway event name / last voice event summary | "What's the bot doing right now?" stays honest |
| Bot uptime start timestamp | Both dashboards agree on uptime |
| Active voice presences | Voice tab on the Failover shows current members |
| Command log + voice log | Analytics page is identical on both nodes |
| Conversation history (incremental) | AI replies pick up exactly where Primary left off after promotion |
| Config files (when changed) | Automations, rules, etc. carry over |

Sync runs Primary → Failover on a ~60-second tick. After a fresh pair, the first tick fills everything in within a minute.

> **Note** — the Failover still keeps its own Discord gateway connection open in **passive mode** (`outputAllowed = false`) so it can take over instantly on promotion without a reconnect delay. Every Discord write path (sendMessage, slash registration, voice updates) is gated until promotion flips the output gate on.

---

## 8. How failover detection works

The Failover watches the Primary continuously and promotes itself if the Primary is *clearly* dead. The logic is intentionally conservative — false promotions are worse than a few extra seconds of downtime.

**Step-by-step**

1. **Health probe loop (every ~5 s)** — Failover pings the Primary's mesh listener (`/cluster/ping`). A single miss is ignored (one quick retry filters network jitter).
2. **Miss counter** — each confirmed miss increments a counter. The Failover updates `clusterSnapshot.diagnostics` with the running tally (`Primary health miss 2/3`).
3. **Threshold tripped** — after a few consecutive misses, the Failover enters confirmation mode instead of promoting immediately. It runs three independent checks:
   - **(a) Generous-timeout retries** — two extra mesh probes with a 10 s timeout each. If either succeeds, the misses were transient — abort.
   - **(b) Final tail-resync pull** — best-effort attempt to fetch the latest records from the Primary. If this succeeds, the Primary is alive too — abort, merge anything new, stay Standby.
   - **(c) `/live` second signal** — if the Primary publishes a public URL (Cloudflare tunnel or custom reverse proxy), the Failover does an HTTPS `GET /live`. Any response of **`200 + body "online"`** means the Primary is still serving Discord. If `/live` says so, **abort the promotion** and log *"Direct mesh probe failed, but Primary still answers /live publicly — promotion aborted (routing issue suspected)"*.

   If all three checks agree the Primary is gone, promote.

**Why the `/live` signal matters**

The direct mesh socket and the public `/live` URL travel completely different paths:

| Path | What it tests |
| --- | --- |
| Direct mesh (`/cluster/ping`) | Failover → Primary TCP path. Breaks if Failover's WAN flaps or Primary's port forward goes down. |
| `/live` over Cloudflare | Failover → Cloudflare edge → Primary tunnel. Outbound only on both ends, works through NAT, only fails when the Primary process is actually dead. |

If the **mesh fails but `/live` is fine**, you're looking at a routing problem (Failover's connection died, Primary's port-forward dropped, etc.) — *not* an outage. The Failover stays Standby and the issue self-corrects when the route recovers.

If **both fail**, the Primary really is down — Failover promotes.

**Fallback when no public URL is configured**

If the Primary doesn't have a Cloudflare tunnel or public base URL set, the `/live` check returns "unknown" and is skipped. Failover detection falls back to the mesh-only path (checks a + b above). That's still safe — the tail-resync stage doubles as a final liveness probe — it just loses the cross-path redundancy.

---

## 9. Handover Test — rehearse without an outage

The Primary's SwiftMesh tab has a **Run Handover Test** button (visible when at least one Failover is registered). This is a controlled rehearsal of the promote-and-reclaim path so you can verify everything actually swings before you ever need it in anger.

**What happens**

1. Click **Run Handover Test** on the Primary.
2. The test is **scheduled 90 seconds in the future** (not started immediately). The scheduled timestamp is published in the next mesh-sync tick, so both nodes show a countdown:
   - Primary's HandoverTestPanel: *"Starts at 2:34:15 PM — in 01:28. Failover will be notified on its next sync."*
   - Failover's banner: *"Handover Test scheduled — Starts at 2:34:15 PM — in 00:43."*
3. The 90 s lead time guarantees at least one full ~60 s sync window for the Failover to learn about the test, even when the Primary can't reach the Failover directly (residential NAT).
4. You can **Cancel** the scheduled test at any point before T0 from either node.
5. At T0 the Primary demotes itself, the Failover promotes for 60 s, then the Primary reclaims. A watchdog on the Primary fires after 75 s as a backstop if anything goes wrong.
6. On success: the *Test Failover handover* panel updates to *"Passed just now"* and the timestamp is persisted.

**Limitations to know**

- The active-test phase (Primary signalling "begin" / "end" to the Failover) currently uses an HTTP callback that needs the Failover to be reachable inbound. On residential NAT, the Failover's port is not forwarded — the callback times out and the Primary reclaims via watchdog after ~75 s. This still confirms the Primary can stand back up; it doesn't confirm the Failover would actually take Discord traffic.
- A future change will replace the callback with both sides acting independently at T0 (purely time-based), which removes the bidirectional reachability requirement.

---

## 10. Worker offload

When the Primary is busy (large guild, heavy AI usage), it can hand off specific job types to connected Standby/Worker nodes:

- **Offload AI replies** — Apple Intelligence and other reply pipelines run on the worker.
- **Offload Wiki lookups** — Wiki Bridge fetches run on the worker.

Configure under **Settings → SwiftMesh → Worker Offload** on the Primary. Each toggle is independent. Offload is opportunistic — if no workers are connected, the Primary runs the job itself.

---

## 11. Auto-reclaim after failover

If a Standby promotes itself because the Primary went down, the former Primary will rejoin as Standby when it comes back. You can have it automatically reclaim Primary once the new Primary has been healthy for a configured window:

**Settings → SwiftMesh → Auto-Reclaim → "Reclaim Primary automatically after failover"** (Primary only).

Set the window in hours (1–72). Turn it off to require manual promotion.

---

## 12. The `/live` endpoint (monitoring + failover signal)

Every node with Web UI enabled serves `GET /live` publicly (no auth) on whatever base URL the dashboard is reachable at. It serves two purposes.

### As a uptime monitor probe

Plain-text body, content-negotiated:

| Request | Response | Body |
| --- | --- | --- |
| `curl https://your-domain.com/live` | `200 OK` | `online` *or* `offline` |
| Browser (Accept: text/html) | `200 OK` | Styled status page — *"SwiftBot - Dev is online ✓"* with the bot's avatar/name and a green tick-themed background. |
| Primary process down / tunnel down | (timeout, 502, etc.) | n/a — the request itself fails |

Point UptimeRobot / BetterStack / k8s probes at it. `Cache-Control: no-store` is set so monitors always get the live state.

### As the failover second-signal probe

The Failover uses the **same endpoint** as a cross-path reachability check (see [§8](#8-how-failover-detection-works)). Because the request travels via Cloudflare's edge — outbound from both nodes — it works through NAT and gives the Standby an independent signal from the direct mesh socket.

The Primary's public URL is auto-discovered: the Primary publishes it in every mesh-sync snapshot (sourced from the active Cloudflare tunnel URL, or the **Override Public Base URL** under **Settings → Web UI**). No configuration needed on the Failover.

If the Primary has no public URL, the `/live` check is skipped and failover detection falls back to mesh-only.

---

## 13. Cloudflare tunnel resilience

The Cloudflare tunnel is what makes the public `/live` (and the rest of the Web UI) reachable — so its health is load-bearing for both monitoring and the failover second signal. SwiftBot watches for two failure modes:

**1. cloudflared crashes or exits.**
The TunnelManager's termination handler restarts the process with exponential backoff (2 → 4 → 8 … 30 s), giving up after a few consecutive failures so a bad token doesn't burn CPU forever. The failure budget resets every time the user saves a fresh config.

**2. Network path changes (laptop moves WiFi networks, ISP reconnect, sleep/wake).**
SwiftBot subscribes to macOS's `NWPathMonitor`. On a confirmed change of the available interface set, it:

- Logs *"Network path changed — restarting Cloudflare tunnel for a clean reconnect"*.
- Resets the consecutive-failure counter so a laptop bouncing through networks doesn't hit the lockout.
- Terminates and restarts the cloudflared process, forcing a fresh handshake with Cloudflare's edge.

Most transient flaps (a few dropped packets, a brief WiFi blip) are handled by cloudflared internally and never need a restart — this only kicks in when the underlying network actually changed.

---

## 14. Troubleshooting

**"Public IP lookup failed" warning when copying a Join Code**
SwiftBot tries `api.ipify.org` → `ifconfig.me/ip` → `icanhazip.com` to discover the Primary's WAN IP. If all three are unreachable, the generated code only contains LAN addresses — fine for same-LAN pairing, but off-network Standbys won't be able to connect. Check the Primary's internet access and copy the code again.

**Standby connects on LAN, but I expected the WAN IP to be saved**
By design. The Standby tries the addresses in order, LAN first, and saves the **working** address. If both Macs are on the same network, that's the LAN IP. Move the Standby to a different network and re-pair to switch over to the WAN address.

**"Connection refused" or timeout when pairing across the internet**
Almost always one of:

- Port forwarding not set up on the Primary's router (see [§3](#3-network-topology--what-to-forward)).
- macOS firewall blocking SwiftBot on the Primary (see [§4](#4-macos-firewall)).
- ISP CGNAT — your "public" IP isn't actually reachable from outside. Run a port-check tool from off-network; if `38787` is closed, the Primary needs to be on a network that allows inbound (or fronted by a tunnel/VPS).

**Standbys keep disconnecting after a Rotate Shared Secret**
Expected. Generate a fresh Join Code on the Primary and re-pair each Standby.

**Two SwiftBots on the same Mac**
Set distinct ports — `clusterListenPort` and `clusterLeaderPort` can diverge. Reveal **Advanced Ports** under **Settings → SwiftMesh** to configure them separately.

**"Promotion aborted: leader reachable on confirmation probe" or "routing issue suspected"**
Not an error — the safety net working as intended. The Failover saw mesh failures but the deeper checks (generous-timeout retries / final resync / `/live`) found the Primary was actually fine. This typically means the Failover's network is having a bad time, not the Primary. The Failover will keep watching and try again on the next health miss.

**Handover Test step 3/5: "Could not reach &lt;Failover&gt; — The request timed out"**
Expected when the Failover is behind residential NAT with no inbound port-forward. The active "begin" callback can't reach the Failover, so the Primary's watchdog reclaims after ~75 s. The test still confirms the Primary's reclaim path works. See the *Limitations to know* note in [§9](#9-handover-test--rehearse-without-an-outage).

---

## Related

- [README](README.md) — index of all help articles
- [Bot Setup](BOT_SETUP.md) — Discord application setup that the Primary needs
- [Web UI Setup](WEB_UI_SETUP.md) — exposing the dashboard, where the WebUI Join Code panel lives
