# Risk Matrix for SwiftBot New Features (March 2026)

| Feature | Technical Risk | Mitigation Strategy |
| :--- | :--- | :--- |
| **API Debugging / Checking** | **Token Exposure**: Diagnostic logs might accidentally capture the bot token. | Use `KeychainHelper` for all token access. Ensure `DiscordService` diagnostic outputs redact the token or only report status codes. |
| | **Rate Limiting**: Frequent "Test Connection" clicks could hit Discord API limits. | Implement a UI-level cooldown (e.g., 5 seconds) on the test button. |
| **Welcome New Members** | **Spam/Raid Vulnerability**: A large influx of members could trigger a "message storm" and get the bot banned. | Implement a "burst guard" in `RuleEngine` to cap welcome messages per minute. |
| | **Privacy**: Publicly welcoming members in voice might be undesirable in some servers. | Ensure the feature is opt-in per-guild and supports specific channel targeting. |
| **Splash / Welcome Screen** | **Onboarding Loop**: Logic errors could trap users in the setup screen even with a valid token. | Provide a "Manual Skip" or "Advanced Settings" escape hatch in the onboarding UI. |
| | **Invite Link Security**: Incorrect permission bits in the generated link could lead to a dysfunctional bot. | Use a hardcoded, verified permission integer (274877991936) [Baseline] in the URL generator. |
| **Beta App Icon** | **Runtime Failures**: `NSApp.applicationIconImage` might fail or cause visual glitches on older macOS versions. | Wrap icon switching in a safe macOS version check. Provide a fallback to the default icon. |
| | **Build Pipeline Complexity**: If using build scripts, it might break CI/CD pipelines. | Prefer runtime detection based on `Bundle` metadata to keep the build process simple. |
| **Clear API Key** | **Data Loss**: Clearing the key might be confused with deleting all settings. | Use clear button labeling and a destructive action confirmation dialog. |

**Overall Project Risk:**
- **Code Bloat**: Adding many UI-only features to `RootView.swift` (already ~2450 LOC) will worsen maintainability.
- **Mitigation**: This reinforces the need for the Phase C `RootView` modularization (breaking it into feature files).
