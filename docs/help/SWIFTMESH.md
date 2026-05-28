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
7. [Worker offload](#7-worker-offload)
8. [Auto-reclaim after failover](#8-auto-reclaim-after-failover)
9. [Troubleshooting](#9-troubleshooting)

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

## 7. Worker offload

When the Primary is busy (large guild, heavy AI usage), it can hand off specific job types to connected Standby/Worker nodes:

- **Offload AI replies** — Apple Intelligence and other reply pipelines run on the worker.
- **Offload Wiki lookups** — Wiki Bridge fetches run on the worker.

Configure under **Settings → SwiftMesh → Worker Offload** on the Primary. Each toggle is independent. Offload is opportunistic — if no workers are connected, the Primary runs the job itself.

---

## 8. Auto-reclaim after failover

If a Standby promotes itself because the Primary went down, the former Primary will rejoin as Standby when it comes back. You can have it automatically reclaim Primary once the new Primary has been healthy for a configured window:

**Settings → SwiftMesh → Auto-Reclaim → "Reclaim Primary automatically after failover"** (Primary only).

Set the window in hours (1–72). Turn it off to require manual promotion.

---

## 9. Troubleshooting

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

---

## Related

- [README](README.md) — index of all help articles
- [Bot Setup](BOT_SETUP.md) — Discord application setup that the Primary needs
- [Web UI Setup](WEB_UI_SETUP.md) — exposing the dashboard, where the WebUI Join Code panel lives
