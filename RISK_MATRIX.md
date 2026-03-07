# SwiftBot Risk Matrix (Reviewed March 2026)

This matrix was reviewed against the current repository state on 2026-03-08.
It replaces the older feature-planning matrix and focuses on active product and
engineering risks visible in the current codebase.

## Active Risks

| Area | Current Risk | Likelihood | Impact | Current Controls | Recommended Next Step |
| :--- | :--- | :---: | :---: | :--- | :--- |
| **Secrets at Rest** | The Discord bot token is migrated to Keychain, but `openAIAPIKey` and `clusterSharedSecret` still serialize with `BotSettings` and are written to `settings.json`. A local disk compromise exposes third-party credentials and mesh auth secrets. | High | High | `ConfigStore` clears `settings.token` before disk write and `KeychainHelper` stores the Discord token securely. UI fields for token, cluster secret, and OpenAI key use `SecureField`. | Move `openAIAPIKey` and `clusterSharedSecret` into Keychain-backed storage and keep only redacted placeholders in `settings.json`. |
| **SwiftMesh Contract Drift** | SwiftMesh networking behavior is internally inconsistent: `normalizedBaseURL` honors `:80`/`:443` for explicit schemes, while tests still expect the configured mesh port for those cases. That leaves docs, tests, and runtime behavior out of alignment. | High | High | Mesh auth is HMAC-signed, stale `leaderTerm` syncs are rejected, and metadata/wildcard hosts are blocked. | Decide the canonical port-normalization policy, then align `ClusterCoordinator`, tests, and docs in one pass. |
| **AI Provider Reliability** | AI behavior is operationally inconsistent across providers. The Foundation Models spike test is currently failing on p95 latency and one quality gate, which means DM/assistant features can be slow or produce off-policy replies on some machines. | High | Medium | Provider status checks exist, Apple/Ollama/OpenAI can be toggled, and the DM pipeline already supports provider fallback. | Add a stricter runtime SLA for Apple Intelligence, degrade earlier to fallback providers, and keep the spike test green before expanding AI scope. |
| **OpenAI Cost Control Bypass** | OpenAI image usage limits are tracked in local settings only. That makes the quota easy to reset by editing settings, reinstalling, or using another node, and the limit is not mesh-wide. | Medium | Medium | There is a per-user monthly counter and configurable monthly limit for image generation. | Store usage in a tamper-resistant shared store or replicate it across SwiftMesh nodes, and add an operator-visible hard cap. |
| **Sparkle Release Pipeline** | Auto-update health depends on the appcast feed, signing key, and release publishing staying in sync. If the appcast is stale or `SUFeedURL` / `SUPublicEDKey` are wrong, updates silently stop working in production. | Medium | Medium | `AppUpdater` surfaces whether Sparkle is configured, and the Info plist already carries a stable feed URL and public key. | Add a release checklist or CI validation for appcast generation, signing, and published feed reachability. |
| **No Automated CI Gate** | The repo currently has a Pages workflow but no build/test workflow. Regressions depend on manual local testing and can land without a machine-checked signal. | High | Medium | The package has a meaningful test suite and `swift test` can be run locally. | Add a minimal GitHub Actions workflow for `swift test` and, if practical, a release build smoke check. |
| **UI Maintainability** | `RootView.swift` is still very large and concentrates onboarding, settings, AI, diagnostics, and mesh UI in one file. That increases coupling and makes routine feature edits riskier than they need to be. | High | Medium | Some domain logic has already been split into `AppModel` extensions and companion views. | Break `RootView` into focused feature views, starting with onboarding/settings/AI sections where state churn is highest. |

## Risks Already Materially Reduced

- **Discord token exposure on disk** has been reduced: `ConfigStore` persists an empty `token` field and uses `KeychainHelper` for the live credential.
- **Member-join raid spam** is partially mitigated: the app now has a join burst guard, dedupe window, and template sanitization for welcome flows.
- **SwiftMesh split-brain and auth regressions** are materially lower than before: HMAC auth, stale-term rejection, and cursor monotonicity checks are now in place.
- **Sparkle misconfiguration visibility** is better than before: the UI now exposes update-channel state and warns when appcast configuration is incomplete.

## Recommended Priority Order

1. Move `openAIAPIKey` and `clusterSharedSecret` out of `settings.json`.
2. Resolve the SwiftMesh port-normalization mismatch and return the failing tests to green.
3. Add a basic CI workflow so test regressions are caught automatically.
4. Split `RootView.swift` into smaller feature views before more UI work lands there.
