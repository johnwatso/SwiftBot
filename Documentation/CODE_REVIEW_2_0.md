# SwiftBot 2.0 code review — 7 October 2026

Reviewed the current working tree, including the uncommitted automation, moderation, Events and WebUI changes, against HEAD `d8b6334`. This was a focused release-readiness review of live event dispatch, automation persistence/recovery, WebUI authorization and SwiftMesh output ownership. Findings below come from tracing production code; they are not failures observed against a live Discord server. No fixes or version changes were made.

I recommend resolving the four P1 findings before releasing 2.0. P1 means a security or operational issue to fix before release; P2 means an advertised feature or recovery behavior is incomplete.

1. **[P1] Automation delays hold up the Discord Gateway receive loop.**

   [DiscordGatewayConnection.swift:190](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/DiscordGatewayConnection.swift:190), [DiscordService.swift:718](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/DiscordService.swift:718), [AutomationService.swift:367](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationService.swift:367).

   The socket receive loop awaits `onPayload`, which reaches `fireRules` and awaits each complete automation execution. A delay writes `wakeAt`, then keeps the caller waiting until that time. A message rule with a 600-second delay therefore prevents the receive loop from reading subsequent messages, interactions, voice updates or heartbeat ACKs for ten minutes. Actor reentrancy lets other tasks run, but does not advance this suspended receive loop. The same problem exists for voice-triggered rules and member-event rules reached through AppModel.

   Admit and persist a run promptly, then schedule its continuation independently of socket ingestion. Preserve moderation ordering and the handled-message decision explicitly. Add a Gateway integration test that starts a delayed rule, then verifies a second event and heartbeat ACK are processed before the delay expires. Existing delayed-recovery tests call the engine directly and do not cover this caller chain.

2. **[P1] Live message and voice rules bypass moderation precedence.**

   [DiscordService.swift:716](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/DiscordService.swift:716), [AppModel+Automations.swift:16](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+Automations.swift:16).

   `AppModel.fireAutomations` evaluates moderation first and suppresses ordinary automations after destructive moderation. However, production MESSAGE_CREATE and VOICE_STATE_UPDATE processing uses `DiscordService.fireRules`, which evaluates every category together and executes matches in stored order. With an ordinary reply rule saved before a spam-delete or ban rule, SwiftBot replies to the offending message first; the ordinary rule also runs when moderation is stored first. The moderation tests call `model.fireAutomations` directly, so their passing results do not establish the behavior of live messages.

   Route these event sources through one dispatcher that enforces category precedence. Exercise `processMessageRuleEvent` or the full Gateway callback in the regression test, with automation-before-moderation storage order.

3. **[P1] Viewer accounts can read webhook credentials from automation definitions.**

   [AdminWebServer.swift:3045](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AdminWebServer.swift:3045), [AppModel+AdminWeb.swift:1610](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+AdminWeb.swift:1610), [Automations.swift:450](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Models/Automations.swift:450).

   GET `/api/automations?category=automation` permits an authenticated viewer. The new redaction removes history, diagnostics and event metadata, but returns `payload.rules` unchanged. Each rule includes the full `webhookUrl` and `webhookContent`. For a token-bearing webhook URL, this gives a read-only viewer the credential needed to call the webhook outside SwiftBot. The separate global member gate blocks members; this finding concerns the viewer role.

   Require admin access to full definitions, or return a dedicated viewer projection that removes credential-bearing fields. Add an HTTP authorization test with a populated webhook rule and assert that a viewer response never contains its secret URL or sensitive body.

4. **[P1] Token-bearing webhook URLs are persisted and replicated as ordinary JSON.**

   [AutomationStore.swift:69](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationStore.swift:69), [AutomationExecutionJournal.swift:73](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationExecutionJournal.swift:73), [Persistence.swift:544](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Persistence.swift:544).

   `Automations.Step` encodes the full webhook URL. Saving a rule writes it into `automations.json`; running the rule copies the entire rule into `automation-executions.json`. Both files belong to the shared mesh snapshot. This violates the repository's Keychain-only secret boundary for any webhook whose URL carries its authorization token. File permissions on the journal and encrypted mesh transport do not remove the secret from either on-disk JSON copy. Fixing viewer redaction alone leaves this independent storage issue.

   Persist a credential reference and keep the secret URL or token in Keychain. Resolve it at execution time and use the approved credential-transfer path if followers need it. Migrate existing rule and checkpoint files, and verify serialization and exported mesh snapshots contain no fixture credential.

5. **[P2] Reaction and slash-command automations are exposed without live event wiring.**

   [AppModel+Gateway.swift:444](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+Gateway.swift:444), [AppModel+SlashCommandHelpers.swift:4](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+SlashCommandHelpers.swift:4), [AutomationService.swift:139](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationService.swift:139).

   The editor and template catalog offer `reactionAdded` and `slashCommand`, and the matcher requires the corresponding `MessagePayload.automationTrigger`. The reaction callback is empty. Slash-command registration only includes built-ins and Wiki commands, and interaction handling never creates a slash-command automation event. Assignments of these two synthetic trigger values occur in simulation, not live dispatch. Consequently, the “Starred messages” template never runs and creating the `/rules` automation does not register or execute `/rules`.

   Implement production parsing/dispatch for both triggers and registration plus interaction acknowledgement for automation commands, or remove these choices until supported. Verify each using actual Gateway payload fixtures, rather than `SimulationInput` alone.

6. **[P2] Editing scheduled conditions does not invalidate a waiting run.**

   [AppModel+Automations.swift:94](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/AppModel+Automations.swift:94), [AutomationService.swift:403](/Users/john/Documents/GitHub/SwiftBot/Sources/SwiftBot/Services/AutomationService.swift:403).

   Before a scheduled effect, `scheduledRuleStillValid` compares only enablement, trigger and steps. Changes to `filters`, `filterLogic`, `conditionGroups`, `cooldown` or `failurePolicy` leave this check true. For example, admit a scheduled workflow with a delay, then change its root conditions to exclude the occurrence: the pending run still sends using its saved rule. Changing Stop on failure also leaves the old continuation policy in force. This conflicts with the documented promise that edited scheduled workflows stop before external effects.

   Compare an execution-relevant rule revision or all execution-relevant fields. Test a condition and failure-policy edit during a pending delay, not just a disabled rule or changed step.

Validation completed: Debug and Release app builds succeeded; the complete Debug Xcode test suite passed **857 tests with zero failures**. Release was compiled with `CODE_SIGNING_ALLOWED=NO`; distribution signing, notarization and publishing were not tested. The builds emit repository lint warnings; this review does not establish a warning-free baseline. Live Discord delivery, real two-Mac failover/handback, Cloudflare OAuth and deployed Ruru integration were not exercised. The reliability guide already identifies these live rollout checks as outstanding; passing unit tests should not be treated as their replacement.

At the user's request, created and switched to `2.0-prep` from `main`. Git forbids spaces in branch names. Compared porcelain status before and after switching and confirmed all staged, unstaged and untracked changes were preserved. Everything remains uncommitted, including this report and the roadmap review entry.
