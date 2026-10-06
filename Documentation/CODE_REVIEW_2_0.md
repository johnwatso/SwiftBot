# SwiftBot 2.0 code review — 7 October 2026

Reviewed the current working tree, including the uncommitted automation, moderation, Events and WebUI changes, against HEAD `d8b6334`. This was a focused release-readiness review of live event dispatch, automation persistence/recovery, WebUI authorization and SwiftMesh output ownership. Findings below come from tracing production code; they are not failures observed against a live Discord server. No fixes or version changes were made.

I recommend resolving the four P1 findings before releasing 2.0. P1 means a security or operational issue to fix before release; P2 means an advertised feature or recovery behavior is incomplete.

**Status (7 October 2026, later the same day):** all six findings are fixed in the working tree, each with a regression test. Each finding ends with a **Fixed** note, and [Fixes and remaining limits](#fixes-and-remaining-limits) lists what the fixes deliberately do not cover.

1. **[P1] Automation delays hold up the Discord Gateway receive loop.**

   [DiscordGatewayConnection.swift:190](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/DiscordGatewayConnection.swift:190), [DiscordService.swift:718](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/DiscordService.swift:718), [AutomationService.swift:367](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationService.swift:367).

   The socket receive loop awaits `onPayload`, which reaches `fireRules` and awaits each complete automation execution. A delay writes `wakeAt`, then keeps the caller waiting until that time. A message rule with a 600-second delay therefore prevents the receive loop from reading subsequent messages, interactions, voice updates or heartbeat ACKs for ten minutes. Actor reentrancy lets other tasks run, but does not advance this suspended receive loop. The same problem exists for voice-triggered rules and member-event rules reached through AppModel.

   Admit and persist a run promptly, then schedule its continuation independently of socket ingestion. Preserve moderation ordering and the handled-message decision explicitly. Add a Gateway integration test that starts a delayed rule, then verifies a second event and heartbeat ACK are processed before the delay expires. Existing delayed-recovery tests call the engine directly and do not cover this caller chain.

   **Fixed.** A caller-facing run now returns at its first pending delay. The checkpoint, including `wakeAt`, is already journaled, and the run continues in its own task (`AutomationService.scheduleContinuation`), the same path crash recovery uses. Before returning, the run decides the handled-message question: the message counts as handled if a step already answered it or if a send step is still to come, so the AI reply path does not answer a message a delayed rule will answer. Test: `DiscordGatewayConnectionTests.testDelayedAutomationDoesNotHoldTheReceiveLoop` feeds a 600-second delayed rule, then a second message and a heartbeat ACK, through the real receive loop.

2. **[P1] Live message and voice rules bypass moderation precedence.**

   [DiscordService.swift:716](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/DiscordService.swift:716), [AppModel+Automations.swift:16](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+Automations.swift:16).

   `AppModel.fireAutomations` evaluates moderation first and suppresses ordinary automations after destructive moderation. However, production MESSAGE_CREATE and VOICE_STATE_UPDATE processing uses `DiscordService.fireRules`, which evaluates every category together and executes matches in stored order. With an ordinary reply rule saved before a spam-delete or ban rule, SwiftBot replies to the offending message first; the ordinary rule also runs when moderation is stored first. The moderation tests call `model.fireAutomations` directly, so their passing results do not establish the behavior of live messages.

   Route these event sources through one dispatcher that enforces category precedence. Exercise `processMessageRuleEvent` or the full Gateway callback in the regression test, with automation-before-moderation storage order.

   **Fixed.** Precedence lives in one place, `AutomationService.dispatch`. `DiscordService.fireRules` (messages, voice) and `AppModel.fireAutomations` (members, media, reactions, slash commands) both call it. Test: `AutomationModerationPrecedenceTests.testLiveMessagePathAppliesModerationPrecedence` goes through `processMessageRuleEvent` with the reply rule stored before the ban rule.

3. **[P1] Viewer accounts can read webhook credentials from automation definitions.**

   [AdminWebServer.swift:3045](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AdminWebServer.swift:3045), [AppModel+AdminWeb.swift:1610](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+AdminWeb.swift:1610), [Automations.swift:450](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Models/Automations.swift:450).

   GET `/api/automations?category=automation` permits an authenticated viewer. The new redaction removes history, diagnostics and event metadata, but returns `payload.rules` unchanged. Each rule includes the full `webhookUrl` and `webhookContent`. For a token-bearing webhook URL, this gives a read-only viewer the credential needed to call the webhook outside SwiftBot. The separate global member gate blocks members; this finding concerns the viewer role.

   Require admin access to full definitions, or return a dedicated viewer projection that removes credential-bearing fields. Add an HTTP authorization test with a populated webhook rule and assert that a viewer response never contains its secret URL or sensitive body.

   **Fixed.** Viewers get `AdminWebServer.viewerProjection`, which blanks each webhook step's URL, body and credential reference. Admins no longer receive the URL either (see finding 4); they still get the body because they edit it. Test: `AdminWebServerAuthTests.testViewersNeverSeeWebhookURLsOrBodies`.

4. **[P1] Token-bearing webhook URLs are persisted and replicated as ordinary JSON.**

   [AutomationStore.swift:69](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationStore.swift:69), [AutomationExecutionJournal.swift:73](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationExecutionJournal.swift:73), [Persistence.swift:544](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Persistence.swift:544).

   `Automations.Step` encodes the full webhook URL. Saving a rule writes it into `automations.json`; running the rule copies the entire rule into `automation-executions.json`. Both files belong to the shared mesh snapshot. This violates the repository's Keychain-only secret boundary for any webhook whose URL carries its authorization token. File permissions on the journal and encrypted mesh transport do not remove the secret from either on-disk JSON copy. Fixing viewer redaction alone leaves this independent storage issue.

   Persist a credential reference and keep the secret URL or token in Keychain. Resolve it at execution time and use the approved credential-transfer path if followers need it. Migrate existing rule and checkpoint files, and verify serialization and exported mesh snapshots contain no fixture credential.

   **Fixed.** `AutomationWebhookVault` stores each URL in the Keychain as `automation-webhook.<credential ID>`. Rules keep only `Step.webhookCredentialId`, in memory as well as on disk, so the journal and mesh snapshots never see the URL. `AutomationService` resolves the URL when the step runs. A new URL gets a new ID, so editing a URL changes the rule and its files. References no longer used are deleted from the Keychain. The WebUI field is write-only: blank keeps the saved URL. Standbys copy the URLs through the existing sealed `/v1/mesh/credentials` route (`MeshCredentialsResponse.automationWebhookURLs`). Loading an older `automations.json` or journal moves its inline URLs into the Keychain and rewrites the file. The simulator now names only the webhook's host. Tests: `AutomationRecoveryTests.testWebhookURLsStayInTheKeychain` and `testInlineWebhookURLsFromOlderFilesAreMovedToTheKeychain`. The mesh snapshot copies these files byte for byte, so a clean file means a clean snapshot.

5. **[P2] Reaction and slash-command automations are exposed without live event wiring.**

   [AppModel+Gateway.swift:444](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+Gateway.swift:444), [AppModel+SlashCommandHelpers.swift:4](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+SlashCommandHelpers.swift:4), [AutomationService.swift:139](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationService.swift:139).

   The editor and template catalog offer `reactionAdded` and `slashCommand`, and the matcher requires the corresponding `MessagePayload.automationTrigger`. The reaction callback is empty. Slash-command registration only includes built-ins and Wiki commands, and interaction handling never creates a slash-command automation event. Assignments of these two synthetic trigger values occur in simulation, not live dispatch. Consequently, the “Starred messages” template never runs and creating the `/rules` automation does not register or execute `/rules`.

   Implement production parsing/dispatch for both triggers and registration plus interaction acknowledgement for automation commands, or remove these choices until supported. Verify each using actual Gateway payload fixtures, rather than `SimulationInput` alone.

   **Fixed (implemented, not removed).** `MESSAGE_REACTION_ADD` becomes a `reactionAdded` event. The bot's own reactions are ignored, and each member's reaction is its own run. Emoji matching ignores the variation selector and accepts `:name:` or `<:name:id>` for custom emoji. Enabled `slashCommand` rules are registered as guild commands with an optional `text` option, unless a built-in or Lookup command owns the name. They are re-registered as soon as a rule edit changes the set. An invocation is acknowledged privately within Discord's window, runs through `dispatch`, then closes with "Done.". Command-name matching is now case-insensitive and exact: `/rules` no longer matches `/rulesx`. Tests: `testReactionGatewayPayloadRunsTheStarredMessagesTemplate`, `testSlashInteractionRunsTheAutomationCommand` and `testAutomationSlashCommandsAreRegisteredWithoutTakingBuiltInNames`, all built from Gateway JSON fixtures.

6. **[P2] Editing scheduled conditions does not invalidate a waiting run.**

   [AppModel+Automations.swift:94](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+Automations.swift:94), [AutomationService.swift:403](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationService.swift:403).

   Before a scheduled effect, `scheduledRuleStillValid` compares only enablement, trigger and steps. Changes to `filters`, `filterLogic`, `conditionGroups`, `cooldown` or `failurePolicy` leave this check true. For example, admit a scheduled workflow with a delay, then change its root conditions to exclude the occurrence: the pending run still sends using its saved rule. Changing Stop on failure also leaves the old continuation policy in force. This conflicts with the documented promise that edited scheduled workflows stop before external effects.

   Compare an execution-relevant rule revision or all execution-relevant fields. Test a condition and failure-policy edit during a pending delay, not just a disabled rule or changed step.

   **Fixed.** The check is now `Rule.isExecutionEquivalent(to:)`, which compares every field except the display name. Tests: `testEditedScheduledConditionsCancelAPendingRun`, `testEditedFailurePolicyCancelsAPendingRun`, and `testRenamingAScheduledRuleKeepsItsPendingRun` (a rename alone still sends).

## Fixes and remaining limits

- **Other inline work still holds the receive loop.** Only delays are handed off. A rule's REST calls and AI generation still run inline on the Gateway receive path, as before this review.
- **Replies without a real message to reply to.** "Reply to trigger" now posts in the channel for scheduled and slash-command events. Before, it referenced a message ID that does not exist (`schedule:…` or an interaction ID). A slash-command automation's reply is a channel message, not the interaction's own reply; the invoker sees a private "Done.".
- **Webhook URLs on Standbys.** A Standby keeps the URLs it has copied, including ones the Primary has since replaced or deleted. A pending delayed run whose URL was replaced fails with "the saved webhook URL is missing on this Mac" rather than posting to the old URL. In a mixed-version mesh, an older Standby does not receive webhook URLs, so webhook steps fail after failover until both Macs are updated.
- **Not exercised live:** reaction and slash-command delivery against a real Discord server, and webhook URL handover across a real two-Mac failover.

## Validation

Validation completed (original review): Debug and Release app builds succeeded; the complete Debug Xcode test suite passed **857 tests with zero failures**. Release was compiled with `CODE_SIGNING_ALLOWED=NO`; distribution signing, notarization and publishing were not tested. The builds emit repository lint warnings; this review does not establish a warning-free baseline. Live Discord delivery, real two-Mac failover/handback, Cloudflare OAuth and deployed Ruru integration were not exercised. The reliability guide already identifies these live rollout checks as outstanding; passing unit tests should not be treated as their replacement.

At the user's request, created and switched to `2.0-prep` from `main`. Git forbids spaces in branch names. Compared porcelain status before and after switching and confirmed all staged, unstaged and untracked changes were preserved. Everything remains uncommitted, including this report and the roadmap review entry.

Validation after the fixes: Debug and Release (`CODE_SIGNING_ALLOWED=NO`) app builds succeeded, and the complete Debug Xcode test suite passed **868 tests with zero failures** on DevMini. That is the original 857 plus the 11 regression tests named above.
