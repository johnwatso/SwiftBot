<p align="center">
  <img src="../../assets/readme/app-icon.png" width="100" alt="SwiftBot icon">
</p>

<h1 align="center">Bot Setup Guide</h1>

This guide walks through everything you need to configure on the **Discord Developer Portal** to get SwiftBot running:

1. [Create a Discord application](#1-create-a-discord-application)
2. [Add a bot user and copy its token](#2-add-a-bot-user-and-copy-its-token)
3. [Enable privileged gateway intents](#3-enable-privileged-gateway-intents)
4. [Configure OAuth2 (for the Admin Web UI login)](#4-configure-oauth2-for-the-admin-web-ui-login)
5. [Register redirect URIs](#5-register-redirect-uris)
6. ["Requires OAuth2 Code Grant" — what it is](#6-requires-oauth2-code-grant--what-it-is)
7. [Invite the bot to your server](#7-invite-the-bot-to-your-server)
8. [Troubleshooting](#8-troubleshooting)

All URLs in this document are **examples**. Replace `your-bot.example.com` with whatever public hostname (or `localhost:PORT`) you actually use for your SwiftBot instance.

---

## 1. Create a Discord application

Open the [Discord Developer Portal](https://discord.com/developers/applications) and click **New Application**.

| Field | Value |
| --- | --- |
| Name | Anything — e.g. `MyBot`. This is what shows up in Discord. |
| Team | Personal or a team you own. |

Click **Create**.

> **Tip:** You only need **one** Discord application. The same application provides both the bot user (token) and the OAuth2 client (for users to sign into the Admin Web UI). Splitting them across two applications is supported but adds an extra step — see [Troubleshooting](#two-applications).

---

## 2. Add a bot user and copy its token

From the application page:

1. Open the **Bot** sidebar entry.
2. Click **Add Bot** (or **Reset Token** if a token already exists).
3. Copy the **Bot Token** somewhere safe — Discord will **not** show it again. Treat it like a password.

Paste this token into SwiftBot's onboarding screen. Once it's validated, the app stores it in the macOS Keychain.

> Bot tokens look roughly like `MTE...truncated...XYZ` — a long base64-ish string with two periods.

---

## 3. Enable privileged gateway intents

Still on the **Bot** page, scroll down to **Privileged Gateway Intents** and enable all three:

- **Server Members Intent** — required for member join / leave events.
- **Message Content Intent** — required for any rule or AI feature that reads message text.
- **Presence Intent** — required for voice and online-status tracking.

Save changes at the bottom of the page.

> **Why can't SwiftBot enable these for me?**
> Privileged intents can only be toggled by the application owner through the Discord website. There's no API for it — Discord designed it that way as a safety control so a bot can't silently grant itself elevated access. SwiftBot **requests** these intents when it connects to the Gateway; if any are missing the connection is rejected with **"Disallowed intents specified"** (gateway close code 4014). The Diagnostics tab in the app surfaces this if it happens.

---

## 4. Configure OAuth2 (for the Admin Web UI login)

SwiftBot's Web UI uses **Discord OAuth** so you sign in with your normal Discord account rather than a static password.

On the application page, open **OAuth2 → General**.

1. Copy the **Client ID** and **Client Secret**.
2. In SwiftBot, open **Settings → Web UI → Authentication** and paste them into the **Discord OAuth** card.
3. Enable the Discord provider toggle.

> If you only ever access the dashboard from the macOS app itself, OAuth setup is technically optional. But the dashboard works much better with it configured, and properly registering OAuth also makes bot-invite URLs work in more environments (see [Step 6](#6-requires-oauth2-code-grant--what-it-is)).

---

## 5. Register redirect URIs

Still under **OAuth2 → General**, find **Redirects**. Add the URLs SwiftBot will use for OAuth callbacks.

> Discord rejects any `redirect_uri` that isn't registered here with **"Invalid OAuth2 redirect_uri"**. This is the most common setup error.

**Examples** — pick the ones that match how you actually run SwiftBot:

| Scenario | Redirect URI to add |
| --- | --- |
| Local-only access | `http://localhost:8090/auth/discord/callback` |
| Public access via your own domain | `https://your-bot.example.com/auth/discord/callback` |
| Cloudflare Tunnel using SwiftBot's built-in flow | `https://your-bot.example.com/auth/discord/callback` (the hostname you set in Internet Access) |

You can add multiple redirects. SwiftBot uses the same path (`/auth/discord/callback`) in every case — only the host/port changes.

After saving, SwiftBot's **Settings → Web UI** will show the resolved redirect URI next to the OAuth fields. It should match one of the entries you registered.

---

## 6. "Requires OAuth2 Code Grant" — what it is

On **OAuth2 → General** there's a toggle:

> ☐ **Requires OAuth2 Code Grant**

What it does: if **ON**, Discord refuses any bot-invite URL that doesn't include `response_type=code` and a registered `redirect_uri`. You'll see **"Integration requires code grant."** when clicking an invite link.

What to do:

- **Leave it OFF** if you can — it's the simplest path. Bot-invite URLs work without any extra parameters.
- **Leave it ON** only if you have a specific reason (e.g. compliance, an integrations team requirement). SwiftBot supports this case: it automatically appends `response_type=code` plus your registered admin redirect URI to invite URLs whenever Discord OAuth is configured (Step 4). If you have it ON **and** haven't configured admin OAuth, invites will fail.

There is no functional difference for the bot itself either way — only the invite URL format.

---

## 7. Invite the bot to your server

You have two options:

**A) Let SwiftBot generate the invite URL (recommended)**

After the token is validated in onboarding, SwiftBot shows an **Invite Bot** button. Click it — you'll land on a Discord consent screen, pick the server, and authorize. The URL includes the right scopes, permissions, and (if needed) the code-grant parameters.

**B) Build the URL manually**

If you ever need to construct one yourself (for sharing with someone else, for example):

```
https://discord.com/oauth2/authorize
  ?client_id=YOUR_CLIENT_ID
  &scope=bot+applications.commands
  &permissions=274877991936
  &guild_id=YOUR_SERVER_ID
  &disable_guild_select=true
```

If "Requires OAuth2 Code Grant" is ON, also add:

```
  &response_type=code
  &redirect_uri=https://your-bot.example.com/auth/discord/callback
```

The redirect URI **must** be one you registered in [Step 5](#5-register-redirect-uris).

---

## 8. Troubleshooting

### "Invalid OAuth2 redirect_uri"

Discord didn't recognize the `redirect_uri` you sent.

- Make sure the URL is **registered** under **OAuth2 → Redirects** (Step 5).
- Trailing slash matters. `https://example.com/auth/discord/callback` and `https://example.com/auth/discord/callback/` are different to Discord.
- Scheme matters. `http://localhost` and `https://localhost` are different.
- In SwiftBot, check **Settings → Web UI** — the displayed redirect URI is exactly what's being sent. Copy it verbatim into the Developer Portal.

### "Integration requires code grant."

Your bot application has "Requires OAuth2 Code Grant" enabled and the invite URL didn't include `response_type=code`.

- Easiest fix: turn the toggle OFF (Step 6) unless you have a reason for it.
- Or: configure Discord OAuth in SwiftBot (Step 4) so future generated invites include the right parameters automatically.

### Bot logs in but doesn't see members or messages

Privileged intents aren't enabled. Re-check Step 3 — both **Server Members** and **Message Content** must be ON in the Developer Portal **and** SwiftBot must have been restarted after enabling them.

### "401 Unauthorized" when validating the token

The token was either copied with extra whitespace, or it's a **user token** rather than a **bot token**. Reset the bot token in the Developer Portal and paste the fresh value — it should start with the application's snowflake ID.

### <a name="two-applications"></a>I'm using two separate Discord applications (one bot, one for admin login)

You'll need to register the admin redirect URI on **both** applications' OAuth2 → Redirects, because:

- The admin login flow hits the OAuth application's redirect.
- The bot-invite (when "Requires OAuth2 Code Grant" is ON) also hits a redirect — and that redirect must be registered on the **bot's** application.

If you don't want to register it twice, turn off "Requires OAuth2 Code Grant" on the bot application.

### The Web UI shows "No sign-in method configured"

You enabled the Web UI but haven't added a working OAuth provider or a local fallback. Either:

- Complete Steps 4 and 5 to add Discord OAuth, or
- Enable **Settings → Web UI → Authentication → Local fallback** (development only — username/password).

---

## Related

- [README](../../README.md) — install and overview
- [Architecture](../../ARCHITECTURE.md) — how SwiftBot is wired internally
- [Security](../../SECURITY.md) — token handling and threat model
