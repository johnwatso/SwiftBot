<p align="center">
  <img src="../../assets/readme/app-icon.png" width="100" alt="SwiftBot icon">
</p>

<h1 align="center">Cloudflare Tunnel Setup</h1>

This guide walks through SwiftBot's **Internet Access** feature, which exposes your Admin Web UI on the public internet over a secure Cloudflare Tunnel — no port-forwarding, no manual TLS certificates.

1. [How it works](#1-how-it-works)
2. [Prerequisites](#2-prerequisites)
3. [Create a Cloudflare API token](#3-create-a-cloudflare-api-token)
4. [Configure SwiftBot](#4-configure-swiftbot)
5. [Enable Internet Access](#5-enable-internet-access)
6. [Update Discord OAuth redirects](#6-update-discord-oauth-redirects)
7. [Disabling and changing the hostname](#7-disabling-and-changing-the-hostname)
8. [Troubleshooting](#8-troubleshooting)

All hostnames, tokens, and IDs in this guide are **examples**. Replace `example.com`, `swiftbot`, `swiftbot.example.com`, etc. with your own values.

---

## 1. How it works

When you enable Internet Access, SwiftBot does the following on your behalf using the Cloudflare API:

1. **Detects the zone** that matches your chosen domain (e.g. `example.com`).
2. **Creates (or reuses) a Cloudflare Tunnel** named `swiftbot-<hash>` under your account.
3. **Adds a DNS record** routing your chosen hostname (e.g. `swiftbot.example.com`) into the tunnel.
4. **Issues a TLS certificate** at Cloudflare's edge — your bot's HTTP server stays on `localhost`.
5. **Starts the `cloudflared` process** locally, which holds an outbound TLS connection to Cloudflare. Inbound traffic is reverse-proxied through that connection.

The result: `https://swiftbot.example.com` resolves through Cloudflare, terminates TLS at their edge, and reaches your local SwiftBot. No inbound ports need to be open.

> **Why Cloudflare specifically?** SwiftBot needs a way for Discord's OAuth callback to reach your machine from the public internet without making you set up a static IP, reverse proxy, or DNS records by hand. Cloudflare Tunnel is free, doesn't require credit card details, and integrates with their DNS in one step.

---

## 2. Prerequisites

You need:

- A domain that's **already added to Cloudflare** (you can use a subdomain of an existing one — e.g. `swiftbot.example.com` if `example.com` is in your Cloudflare account).
- The domain's nameservers **pointed at Cloudflare** (the zone shows as **Active** on the Cloudflare dashboard).
- A Cloudflare account with permission to create API tokens.

If you don't have a domain in Cloudflare yet:

1. Buy or transfer one via [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/) or any registrar.
2. Add it to Cloudflare and point the registrar's nameservers at the values Cloudflare gives you.
3. Wait for the status to flip to **Active** before continuing.

---

## 3. Create a Cloudflare API token

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

## 4. Configure SwiftBot

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

## 5. Enable Internet Access

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

## 6. Update Discord OAuth redirects

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

## 7. Disabling and changing the hostname

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
4. Add the new redirect URI to your Discord application (Step 6).

---

## 8. Troubleshooting

### "Cloudflare authentication required"

The token field is empty or the **Verify** button hasn't been clicked. Paste it and click Verify.

### Verify fails with "Invalid token"

- Make sure you copied the token, not the token's **ID**. The token is the long secret shown once after creation.
- Check the token wasn't revoked or expired (Cloudflare dashboard → My Profile → API Tokens).
- The token must have the four permissions listed in [Step 3](#3-create-a-cloudflare-api-token). If you created it with fewer scopes, edit it and add the missing ones, or create a new one.

### Verify succeeds but the zone dropdown is empty

The token's **Zone Resources** scope is too narrow.

- Edit the token and set **Zone Resources → Include → All zones** (or explicitly add the zones you want to choose from).

### "Detect zone" fails

The chosen domain isn't fully active in Cloudflare. Confirm under **DNS → Records** that the zone status shows **Active** and the nameservers are pointed at Cloudflare. New domains can take a few hours.

### "Configure DNS route" fails with "DNS record already exists"

There's already an `A`, `AAAA`, or `CNAME` record for `swiftbot.example.com` in Cloudflare from a previous attempt or another tool.

- Delete the conflicting record under **DNS → Records**, then retry.

### Hostname loads but shows "502 Bad Gateway"

`cloudflared` started but can't reach SwiftBot on localhost.

- Confirm the Admin Web UI is enabled (**Settings → Web UI → Enable Admin Web UI**).
- Confirm the bind port matches (`Settings → Web UI → Advanced → Port`).
- Restart SwiftBot. The Internet Access checklist should re-run cleanly on next launch.

### Discord OAuth fails with "Invalid OAuth2 redirect_uri"

You haven't added the public redirect URI to your Discord application yet. See [Step 6](#6-update-discord-oauth-redirects).

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
