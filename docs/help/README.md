<p align="center">
  <img src="../../assets/readme/app-icon.png" width="100" alt="SwiftBot icon">
</p>

<h1 align="center">SwiftBot Help</h1>

<p align="center">
  Setup walkthroughs and how-to guides for running SwiftBot day to day.
</p>

---

## Setup

| Guide | What it covers |
| --- | --- |
| [Bot Setup](BOT_SETUP.md) | Creating the Discord application, copying the bot token, enabling intents, configuring OAuth2 for the Web UI, registering redirect URIs, and troubleshooting common Discord errors. |

---

## Adding new docs

Drop new help articles into this folder as Markdown files, then list them in the table above.

Conventions:

- File names: `UPPER_SNAKE_CASE.md` to match the rest of the repo (`BOT_SETUP.md`, `WEB_UI_INTERNET_ACCESS.md`, etc.).
- One topic per file. Cross-link between docs with relative links.
- Use example values (`your-bot.example.com`, `localhost:8090`, `MyBot`, fake snowflake IDs) — never real instance data, tokens, or member IDs.
- Where a setting lives in the macOS app, name the path explicitly: **Settings → Web UI → Authentication**.
- Each doc should open with a short summary and a table of contents if it's longer than one screen.

---

## Related

- [README](../../README.md) — overview, install, releases
- [Architecture](../../ARCHITECTURE.md) — how SwiftBot is wired internally
- [Security](../../SECURITY.md) — token handling and threat model
