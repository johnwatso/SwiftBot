<p align="center">
  <img src="../../assets/readme/app-icon.png" width="100" alt="SwiftBot icon">
</p>

<h1 align="center">Web UI Setup</h1>

This guide covers how to enable and access SwiftBot's **Admin Web UI** — the browser-based dashboard that mirrors the macOS app.

1. [Access modes overview](#1-access-modes-overview)
2. [Local-only access](#2-local-only-access)
3. [Public access via Cloudflare Tunnel](#3-public-access-via-cloudflare-tunnel) (recommended)
4. [Public access via your own reverse proxy](#4-public-access-via-your-own-reverse-proxy)
5. [Port forwarding — not supported](#5-port-forwarding--not-supported)
6. [Cloudflare Tunnel step-by-step](#6-cloudflare-tunnel-step-by-step)
7. [Update Discord OAuth redirects](#7-update-discord-oauth-redirects)
8. [Disabling and changing the hostname](#8-disabling-and-changing-the-hostname)
9. [Troubleshooting](#9-troubleshooting)

All hostnames, tokens, and IDs in this guide are **examples**. Replace `example.com`, `swiftbot`, `swiftbot.example.com`, etc. with your own values.

---

## 1. Access modes overview

The Web UI is the same code regardless of how it's exposed. What differs is **how requests reach your machine**:

| Mode | Reachable from | Setup effort | Supported |
| --- | --- | --- | --- |
| **Local-only** | The machine running SwiftBot, on `localhost` | Zero — just toggle Web UI on | ✅ Default |
| **Cloudflare Tunnel** | Anywhere on the public internet, over HTTPS | Cloudflare API token + a domain in Cloudflare | ✅ Recommended |
| **Custom reverse proxy** | Wherever your proxy is reachable | You operate nginx, Caddy, Traefik, etc. | ✅ Supported via "Override Public Base URL" |
| **Port forwarding** | Anywhere, if your router allows inbound | Router config + dynamic DNS + manual TLS | ❌ **Not supported** — see [§5](#5-port-forwarding--not-supported) |

If you only ever need to manage the bot from the same Mac, **local-only is fine**. The remaining modes exist because Discord OAuth callbacks have to reach your dashboard from the public internet.

---

## 2. Local-only access

This is the default. After installing SwiftBot:

1. Open **Settings → Web UI**.
2. Enable **Enable Admin Web UI**.
3. Visit `http://localhost:8090` (or whatever port is set under **Advanced**).

In local-only mode Discord OAuth still works — register `http://localhost:8090/auth/discord/callback` as a redirect URI on your Discord application (see [Bot Setup → Step 5](BOT_SETUP.md#5-register-redirect-uris)).

---

## 3. Public access via Cloudflare Tunnel

SwiftBot's built-in **Internet Access** feature provisions a [Cloudflare Tunnel](https://www.cloudflare.com/products/tunnel/) automatically — no port forwarding, no static IP, no manual TLS. Outbound TLS connection only.

Why Cloudflare is the recommended path:

- Free, no credit card.
- TLS certificates are issued and renewed automatically at Cloudflare's edge.
- DDoS protection and edge caching come for free.
- The connection is **outbound only** from your machine — no inbound firewall rules.

Full walkthrough: [§6 Cloudflare Tunnel step-by-step](#6-cloudflare-tunnel-step-by-step).

---

## 4. Public access via your own reverse proxy

If you already operate a reverse proxy (nginx, Caddy, Traefik, HAProxy, a different tunnel service like Tailscale Funnel or ngrok, etc.), point it at SwiftBot's local port and tell SwiftBot what public URL it's served under.

1. Forward your proxy to `http://localhost:8090` on the SwiftBot host.
2. In SwiftBot, **Settings → Web UI → Advanced**, set **Override Public Base URL** to your public URL — e.g. `https://swiftbot.example.com`.
3. Make sure your proxy terminates TLS — SwiftBot's local server is plain HTTP.
4. Register `https://swiftbot.example.com/auth/discord/callback` as a Discord OAuth redirect URI.

The Cloudflare Tunnel toggle in SwiftBot does **not** need to be enabled in this mode.

> ⚠️ Whatever proxy you run, make sure it doesn't expose anything on the SwiftBot host besides the Web UI port. The bot doesn't expect arbitrary inbound traffic.

---

## 5. Port forwarding — not supported

**Don't open port 8090 (or any other SwiftBot port) directly on your router.** SwiftBot isn't designed to be reached this way and we don't support it.

Reasons:

- **The local server is plain HTTP.** No TLS termination. Bot tokens, session cookies, and OAuth state would travel in clear text across the public internet.
- **No DDoS or rate-limit protection.** Any abuse hits your machine directly.
- **macOS port forwarding is dynamic.** If your ISP's IP changes (it will), the dashboard goes dark until you update DNS manually.
- **Discord OAuth requires HTTPS.** Discord refuses non-HTTPS callbacks for production OAuth flows.
- **No supported configuration field for it.** The Web UI assumes either localhost or a TLS-terminating front-end (tunnel or proxy).

If you genuinely want public access without Cloudflare, run a proxy that handles TLS in front of SwiftBot (see [§4](#4-public-access-via-your-own-reverse-proxy)). That's strictly better in every dimension than raw port forwarding.

---

## 6. Cloudflare Tunnel step-by-step

> ⚠️ **Heads-up: SwiftBot can overwrite existing DNS records.**
>
> If you point SwiftBot at a hostname that already has a DNS record, here's what happens during enable:
>
> - **`A` or `AAAA` records** on that hostname are **silently deleted and replaced** with a CNAME to the tunnel. No prompt.
> - **A `CNAME` pointing to a different target** is **blocked** the first time and SwiftBot asks for explicit override before replacing it.
> - **A `CNAME` already pointing to the correct tunnel target** is left alone.
>
> Pick a brand-new subdomain (`swiftbot`, `dashboard`, `bot-admin`, etc.) if you have any doubt. Don't aim it at a hostname that's already serving production traffic — your existing site will go dark the moment Internet Access is enabled.

### How it works

When you enable Internet Access, SwiftBot does the following on your behalf using the Cloudflare API:

1. **Detects the zone** that matches your chosen domain (e.g. `example.com`).
2. **Creates (or reuses) a Cloudflare Tunnel** named `swiftbot-<hash>` under your account.
3. **Adds a DNS record** routing your chosen hostname (e.g. `swiftbot.example.com`) into the tunnel.
4. **Issues a TLS certificate** at Cloudflare's edge — your bot's HTTP server stays on `localhost`.
5. **Starts the `cloudflared` process** locally, which holds an outbound TLS connection to Cloudflare. Inbound traffic is reverse-proxied through that connection.

The result: `https://swiftbot.example.com` resolves through Cloudflare, terminates TLS at their edge, and reaches your local SwiftBot. No inbound ports need to be open.

> **Why Cloudflare specifically?** SwiftBot needs a way for Discord's OAuth callback to reach your machine from the public internet without making you set up a static IP, reverse proxy, or DNS records by hand. Cloudflare Tunnel is free, doesn't require credit card details, and integrates with their DNS in one step.

---

### Prerequisites

You need:

- A domain that's **already added to Cloudflare** (you can use a subdomain of an existing one — e.g. `swiftbot.example.com` if `example.com` is in your Cloudflare account).
- The domain's nameservers **pointed at Cloudflare** (the zone shows as **Active** on the Cloudflare dashboard).
- A Cloudflare account with permission to create API tokens.

If you don't have a domain in Cloudflare yet:

1. Buy or transfer one via [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/) or any registrar.
2. Add it to Cloudflare and point the registrar's nameservers at the values Cloudflare gives you.
3. Wait for the status to flip to **Active** before continuing.

---

### Create a Cloudflare API token

Cloudflare API tokens are scoped — you grant the **minimum** permissions SwiftBot needs.

Open the [Cloudflare API Tokens page](https://dash.cloudflare.com/profile/api-tokens) and click **Create Token → Get started** (under "Create Custom Token").

Configure it as follows:

| Field | Value |
| --- | --- |
| **Token name** | `SwiftBot Tunnel` (or anything memorable) |
| **Permissions** | Add the four below |
| → 1 | **Account** · **Cloudflare Tunnel** · **Edit** |
| → 2 | **Zone** · **DNS** · **Edit** |
| → 3 | **Zone** · **Zone** · **Read** |
| → 4 | **User** · **User Details** · **Read** |
| **Account Resources** | Include → **All accounts** *(or pick the specific account)* |
| **Zone Resources** | Include → **All zones** *(or pick the specific zone)* |
| **Client IP Address Filtering** | Leave blank |
| **TTL** | Leave blank (no expiry) — or set one if you want to rotate periodically |

Click **Continue to summary**, then **Create Token**.

Cloudflare shows the token **once**. Copy it now and treat it like a password.

> A token looks like: `1234567890abcdefghijklmnopqrstuvwxyz_AB-CD`. About 40 characters.

---

### Configure SwiftBot

In SwiftBot, open **Settings → Web UI → Internet Access**.

1. **Cloudflare API Token** — paste your token and click **Verify**.

   SwiftBot makes a no-op API call to confirm the token works and discovers your account + zone list. On success you'll see a green checkmark.

2. **Hostname** — choose your **subdomain** and pick a **zone** from the dropdown.

   - Subdomain: lowercase letters, numbers, hyphens. Example: `swiftbot`.
   - Zone: the domain you have in Cloudflare. Example: `example.com`.

   The live preview shows the final URL: `https://swiftbot.example.com`.

3. The checklist on the right shows pending steps; everything past **Verify Cloudflare API** stays in **Pending** state until you enable.

> **Tip:** You can use any subdomain. `bot`, `dashboard`, `swift`, `admin` — whatever you like. The only requirement is that the resulting hostname doesn't conflict with an existing DNS record in that zone.

---

### Enable Internet Access

Flip the **Enable Internet Access** toggle at the top of the section.

SwiftBot runs through six steps automatically. Each appears in the checklist with a live status:

| Step | What happens |
| --- | --- |
| 1. Verify Cloudflare API | Re-checks the token is still valid. |
| 2. Detect zone | Confirms `example.com` is associated with your account. |
| 3. Detect or create tunnel | Reuses `swiftbot-<hash>` if it exists, otherwise creates it. |
| 4. Configure DNS route | Adds a CNAME `swiftbot.example.com → <tunnel-id>.cfargotunnel.com`. |
| 5. Issue HTTPS certificate | Cloudflare provisions an edge certificate. |
| 6. Enable Internet Access | Starts `cloudflared` locally; the dashboard becomes reachable. |

Setup typically takes 10–30 seconds. When all rows turn green, the URL preview becomes a link — click it to open the dashboard in your browser.

> **Failover note:** Cloudflare Tunnel can only be enabled on the **Primary** node of a SwiftMesh cluster. Failover nodes show a warning and the toggle is read-only.

---

## 7. Update Discord OAuth redirects

If you signed in with Discord OAuth before enabling Internet Access, your redirect URI was the local one (`http://localhost:8090/auth/discord/callback`). Now that the dashboard has a public hostname, you need to **add** the new redirect to your Discord application.

1. Open the [Discord Developer Portal](https://discord.com/developers/applications) → your app → **OAuth2 → Redirects**.
2. Click **Add Redirect** and paste:

   ```
   https://swiftbot.example.com/auth/discord/callback
   ```

3. **Save**.

You can keep both the local and public redirects registered — SwiftBot will use whichever matches the host you're visiting.

For full Discord OAuth setup details, see [Bot Setup → Step 5](BOT_SETUP.md#5-register-redirect-uris).

---

## 8. Disabling and changing the hostname

### Temporarily disable

Toggle **Enable Internet Access** off. SwiftBot stops `cloudflared` immediately. The DNS record and tunnel definition stay in your Cloudflare account so you can re-enable without re-running setup.

### Permanently remove

1. Disable Internet Access in SwiftBot.
2. Delete the DNS record in the Cloudflare dashboard (**DNS → Records**) — search for your hostname.
3. Delete the tunnel in **Zero Trust → Networks → Tunnels** — search for `swiftbot-`.

### Change the hostname

1. Disable Internet Access.
2. Update the subdomain or zone in SwiftBot.
3. Re-enable. SwiftBot creates a new DNS record. The old one stays unless you delete it manually.
4. Add the new redirect URI to your Discord application ([§7](#7-update-discord-oauth-redirects)).

---

## 9. Troubleshooting

### "Cloudflare authentication required"

The token field is empty or the **Verify** button hasn't been clicked. Paste it and click Verify.

### Verify fails with "Invalid token"

- Make sure you copied the token, not the token's **ID**. The token is the long secret shown once after creation.
- Check the token wasn't revoked or expired (Cloudflare dashboard → My Profile → API Tokens).
- The token must have the four permissions listed under [Create a Cloudflare API token](#create-a-cloudflare-api-token). If you created it with fewer scopes, edit it and add the missing ones, or create a new one.

### Verify succeeds but the zone dropdown is empty

The token's **Zone Resources** scope is too narrow.

- Edit the token and set **Zone Resources → Include → All zones** (or explicitly add the zones you want to choose from).

### "Detect zone" fails

The chosen domain isn't fully active in Cloudflare. Confirm under **DNS → Records** that the zone status shows **Active** and the nameservers are pointed at Cloudflare. New domains can take a few hours.

### "Configure DNS route" prompts to override an existing CNAME

The hostname already has a `CNAME` pointing somewhere other than the tunnel target. SwiftBot blocks the operation by default so you don't accidentally clobber a production record.

- If the existing CNAME is no longer needed, click the override action — SwiftBot will delete it and create the tunnel CNAME in its place.
- If it **is** needed, pick a different subdomain in SwiftBot instead.

> `A` and `AAAA` records on the same hostname are replaced silently — no prompt. See the warning at the top of this guide.

### Hostname loads but shows "502 Bad Gateway"

`cloudflared` started but can't reach SwiftBot on localhost.

- Confirm the Admin Web UI is enabled (**Settings → Web UI → Enable Admin Web UI**).
- Confirm the bind port matches (`Settings → Web UI → Advanced → Port`).
- Restart SwiftBot. The Internet Access checklist should re-run cleanly on next launch.

### Discord OAuth fails with "Invalid OAuth2 redirect_uri"

You haven't added the public redirect URI to your Discord application yet. See [§7 Update Discord OAuth redirects](#7-update-discord-oauth-redirects).

### Want to use a different DNS provider?

Internet Access is Cloudflare-specific today. If your domain isn't in Cloudflare you have two options:

- Move the domain (or just a subdomain delegation) to Cloudflare.
- Use a reverse proxy you manage yourself (nginx, Caddy, etc.) and set **Settings → Web UI → Advanced → Override Public Base URL** to whatever public URL it serves.

---

## Related

- [Bot Setup Guide](BOT_SETUP.md) — Discord token, intents, OAuth
- [Help index](README.md)
- [README](../../README.md) — install and overview
- [Security](../../SECURITY.md) — token handling and threat model
