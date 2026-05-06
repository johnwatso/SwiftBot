# Security Policy

## Supported Versions

The following versions of SwiftBot are currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| < 1.0   | :x:                |

## Security Guarantees

- **No Discord Password Storage:** SwiftBot uses a Discord bot token. Your personal Discord password is never entered, handled, or stored by the application.
- **Keychain Token Storage:** Discord bot tokens are stored securely in macOS Keychain.
- **Local Runtime Data:** SwiftBot stores settings, rules, logs, cached Discord metadata, and SwiftMesh cursors locally in your Application Support directory.
- **Direct Discord Connection:** Discord Gateway and REST API calls are made directly from your local machine to Discord. SwiftBot does not proxy bot tokens, messages, or server metadata through a third-party service.
- **Primary-Only Discord Output:** SwiftMesh is designed so only the active primary node sends Discord output, reducing the risk of duplicate clustered bot actions.

## Security Scope & Limitations

- **Bot Token Access:** Anyone with access to your unlocked Mac user account or Keychain may be able to use saved bot credentials. Protect your macOS account with a strong password and device security settings.
- **Discord Permissions:** SwiftBot can only act within the permissions granted to the bot in Discord. Review bot roles, channel permissions, and privileged gateway intents carefully.
- **Local Configuration Files:** Non-secret configuration is stored locally in Application Support. Treat backups and synced copies of that folder as potentially sensitive because they may contain server IDs, channel IDs, cached metadata, and automation rules.
- **Admin Web UI:** If the Admin Web UI or remote access features are enabled, bind addresses, access tokens, OAuth settings, certificates, and tunnel configuration should be reviewed before exposing the dashboard beyond localhost or a trusted network.
- **SwiftMesh Networking:** SwiftMesh peers should only be configured between machines you control. Keep mesh secrets private and avoid running a mixed-trust cluster.
- **Third-Party APIs:** Patchy, WikiBridge, AI providers, Discord, and vendor update sources may change behavior independently of SwiftBot. Keep SwiftBot updated and review provider terms for your own use case.
