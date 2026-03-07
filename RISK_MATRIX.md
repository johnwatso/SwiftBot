# SwiftBot Risk Matrix (Reviewed March 2026)

This matrix was reviewed against the current repository state on 2026-03-08.
It replaces the older feature-planning matrix and focuses on active product and
engineering risks visible in the current codebase.

## Active Risks

| Area | Current Risk | Likelihood | Impact | Current Controls | Recommended Next Step |
| :--- | :--- | :---: | :---: | :--- | :--- |
| ~~**Secrets at Rest**~~ | ~~The Discord bot token is migrated to Keychain, but `openAIAPIKey` and `clusterSharedSecret` still serialize with `BotSettings` and are written to `settings.json`. A local disk compromise exposes third-party credentials and mesh auth secrets.~~ | ~~High~~ | ~~High~~ | **Resolved 2026-03-08.** `openAIAPIKey` and `clusterSharedSecret` are now Keychain-backed (`"openai-api-key"` and `"cluster-shared-secret"` accounts). `ConfigStore` auto-migrates existing disk values on first load and writes only empty strings to `settings.json`. | — |
| **SwiftMesh Contract Drift** | SwiftMesh networking behavior is internally inconsistent: `normalizedBaseURL` honors `:80`/`:443` for explicit schemes, while tests still expect the configured mesh port for those cases. That leaves docs, tests, and runtime behavior out of alignment. | High | High | Mesh auth is HMAC-signed, stale `leaderTerm` syncs are rejected, and metadata/wildcard hosts are blocked. | Decide the canonical port-normalization policy, then align `ClusterCoordinator`, tests, and docs in one pass. |
| ~~**AI Provider Reliability**~~ | ~~AI behavior is operationally inconsistent across providers. The Foundation Models spike test is currently failing on p95 latency and one quality gate.~~ | ~~High~~ | ~~Medium~~ | **Resolved 2026-03-08.** Root cause was test-side: spike tests were not using the `Transcript` API to pass system instructions, causing the model to ignore them. After fix: p95 latency 11,756ms → 801ms, quality 4/5 → 5/5, all FoundationModels tests green. | — |
| ~~**OpenAI Cost Control Bypass**~~ | ~~OpenAI image usage limits are tracked in local settings only. That makes the quota easy to reset by editing settings, reinstalling, or using another node, and the limit is not mesh-wide.~~ | ~~Medium~~ | ~~Medium~~ | **Resolved 2026-03-08.** Implemented mesh-wide usage synchronization via `MeshSyncPayload`. Added `openAIImageMonthlyHardCap` (default 100) and cluster-wide aggregation in `handleGenerateImageCommand`. Primary node now broadcasts updated usage counts immediately. | — |
| ~~**Sparkle Release Pipeline**~~ | ~~Auto-update health depends on the appcast feed, signing key, and release publishing staying in sync. If the appcast is stale or `SUFeedURL` / `SUPublicEDKey` are wrong, updates silently stop working in production.~~ | ~~Medium~~ | ~~Medium~~ | **Resolved 2026-03-08.** Created `scripts/validate_sparkle.sh` which verifies Plist keys, stable appcast presence, and enclosure reachability. Integrated this script as a mandatory step in the `ci.yml` workflow. | — |
| ~~**No Automated CI Gate**~~ | ~~The repo currently has a Pages workflow but no build/test workflow. Regressions depend on manual local testing and can land without a machine-checked signal.~~ | ~~High~~ | ~~Medium~~ | **Resolved 2026-03-08.** `.github/workflows/ci.yml` added. Runs `swift test --parallel` and `swift test --package-path Sources/UpdateEngine --parallel` on push/PR to main, on `macos-14`. | — |
| ~~**UI Maintainability**~~ | ~~`RootView.swift` is still very large and concentrates onboarding, settings, AI, diagnostics, and mesh UI in one file.~~ | ~~High~~ | ~~Medium~~ | **Resolved 2026-03-08.** `RootView.swift` reduced from ~4300 to ~350 lines. Extracted: `OnboardingView.swift`, `OverviewView.swift`, `VoiceActionsView.swift`, `CommandsView.swift`, `LogsView.swift`, `AIBotsView.swift`, `SettingsView.swift`, `CommonUI.swift`. Model types (`Rule`, `TriggerType`, `ActionType`, etc.) moved to `Models.swift`. | — |

## Risks Already Materially Reduced

- **Discord token exposure on disk** has been reduced: `ConfigStore` persists an empty `token` field and uses `KeychainHelper` for the live credential.
- **Member-join raid spam** is partially mitigated: the app now has a join burst guard, dedupe window, and template sanitization for welcome flows.
- **SwiftMesh split-brain and auth regressions** are materially lower than before: HMAC auth, stale-term rejection, and cursor monotonicity checks are now in place.
- **Sparkle misconfiguration visibility** is better than before: the UI now exposes update-channel state and warns when appcast configuration is incomplete.

## Recommended Priority Order

1. ~~Move `openAIAPIKey` and `clusterSharedSecret` out of `settings.json`.~~ ✅ Done 2026-03-08
2. Resolve the SwiftMesh port-normalization mismatch and return the failing tests to green. *(in progress — @codex)*
3. ~~Add a basic CI workflow so test regressions are caught automatically.~~ ✅ Done 2026-03-08
4. ~~Split `RootView.swift` into smaller feature views before more UI work lands there.~~ ✅ Done 2026-03-08
5. ~~Implement mesh-wide image usage tracking and hard caps for OpenAI cost control.~~ ✅ Done 2026-03-08
6. ~~Automate Sparkle release pipeline validation in CI.~~ ✅ Done 2026-03-08
