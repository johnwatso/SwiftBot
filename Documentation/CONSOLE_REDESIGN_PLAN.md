# SwiftBot Console Redesign — Web UI First

Status: proposal (2026-10-03). Nothing in this document is implemented yet.

## Goal

Make the admin web UI the main way people manage SwiftBot. The native Mac app
becomes a host console in the style of the old macOS Server app, following the
Apple HIG. It handles setup, the services' lifecycle, health checks, access and
logs, and it hands off to the browser for feature configuration.

## Target layout (native)

`NavigationSplitView` with a full-height sidebar, a unified toolbar
(title, subtitle, Stop/Start, and an "Open in Browser" button), and detail panes
built from `Form { … }.formStyle(.grouped)`.

Sidebar:

| Section  | Row             | Pane contents |
| -------- | --------------- | ------------- |
| Server   | This Mac        | Segmented control (Overview / Settings / Storage). Status group (guilds, gateway latency, mesh nodes, memory), Network group (host name, web UI address, bot account), and a footnote pointing to the web UI. |
| Server   | Access          | Bot token (Replace…), Invite Bot, who can sign in to the web UI, operators. |
| Server   | Logs            | Live log, Export Logs…, the audit trail. |
| Server   | Alerts          | Health warnings (from `OverviewHealth`), and failed updates or certificate problems. Shows a badge count. |
| Services | Admin Web UI    | Enable toggle, address and domain, certificate or DNS override, sign-in restrictions, active sessions, Open in Browser. |
| Services | Discord Gateway | Connection state, reconnect, a bot permissions check. |
| Services | SwiftMesh       | Role, ports, shared secret (Rotate), worker offload, Test Connection. |
| Services | Voice           | Announcer engine and voice status, audio device. |
| Services | Recordings      | Enable toggle, recordings folder, disk usage. |
| Services | Intelligence    | Whether Apple Intelligence is available, and the model's status. |
| Services | Software Update | Check Now…, automatic and unattended update toggles, release channel. |

Every service pane has the same shape. The first row is the service's icon,
name and status with an on/off `Toggle`. Below that come a Health group
(status, last restart, Start Automatically), and the footer buttons are
"Show Logs" and "Configure in Browser…".

The feature pages leave the native app: Commands, Welcome Flow, Automations,
Moderation, Activity, Lookup, Announcer rules, Analytics, Rewind, Sweep,
Game Tracker and Patchy. On the native side these become "Configure in
Browser…" deep links.

## Steps

1. **Web parity first.** Close the gaps listed below so nothing becomes
   unreachable when the native feature pages go. Don't remove anything native
   until its web replacement has shipped.
2. **Deep links.** Give each web UI view and settings group a stable URL, such
   as `/#/automations` or `/#/settings/apple-intelligence`, so the native
   "Configure in Browser…" buttons land on the right page. Add a
   `func openWebUI(_ route: String)` helper on `AppModel+AdminWeb.swift` that
   uses the current address and, ideally, a sign-in token valid for one use,
   so the person isn't asked to sign in again on the same Mac.
3. **New console shell.** Add a `ConsoleRootView` that sits alongside
   `RootView`, driven by a new `ConsoleItem` enum with `server` and `services`
   groups. Keep `SidebarLayoutTests`-style coverage so every item is listed
   exactly once. Put it behind a setting (for example "Use console layout") so
   both layouts ship side by side for a release.
4. **Server panes.** Move the host-level controls out of
   `PreferencesView` (General, Web UI, SwiftMesh, Updates, Developer,
   Integrations) into the server and service panes. Most of the existing
   `Form` content can be reused as-is. The Preferences window then shrinks to
   app-level items: appearance, menu bar or Dock, and Developer.
5. **Service model.** Add a small `ConsoleService` protocol or descriptor
   (id, name, symbol, status, `isEnabled` binding, `webRoute`). Then the
   service panes are one generic view plus a custom section where needed.
   Status comes from the existing `AppModel` state, so no new architecture
   layer is needed.
6. **Alerts.** Turn `OverviewHealth` findings into a list with a sidebar badge.
   Optionally post a `UNUserNotification` for anything critical.
7. **Remove the native feature pages.** Once the web versions are proven,
   delete the native feature views (`CommandsView`, `AutomationsView`,
   `ModerationView`, `PatchyView`, `SweepView`, `GameTrackerView`,
   `RewindView`, `AnalyticsView`, `WikiBridgeView`, `WelcomeFlowView`,
   `VoiceView` rules, `ActivityLogView`). Do this one or two at a time, each in
   its own release.
8. **Onboarding.** Keep the native first-run flow (`OnboardingRootView`,
   `StandaloneSetupView`, `RemoteSetupView`, `SwiftMeshSetupView`), since it
   has to work before the web UI exists. It should end with "Open in Browser".
   Restyle it to match Server.app's setup assistant.

## Gaps to check: things that may be missing from the web UI

These come from comparing `SidebarItem`, the native preferences, and native-only
views against `Resources/admin/index.html`. Each needs a check by hand before
step 7.

**Probably missing from the web UI:**

- **Automation simulation.** `AutomationSimulationResultView` has no web
  equivalent; `index.html` has no matches for "simulat". Rule testing needs a
  web version before `AutomationsView` goes.
- **Bot permissions check.** `BotPermissionsCheckView` has only one weak match
  for "permission" in the web UI.
- **Rule editor details.** `AutomationRuleEditor` and
  `VariableAutocompleteField` need the web editor to offer the same variable
  autocomplete.
- **User timezones.** `UserTimezonesView` has "timezone" mentions in the web
  UI, but it's unclear whether there's a management screen.
- **Game provider configuration.** `GameProviderConfigurationSheet` may only
  partly exist on the web side, which has "provider" matches but no confirmed
  sheet.
- **SwiftMiner pairing.** `SwiftMinerPairingSheet` has "pair" mentions in the
  web UI; confirm pairing can be finished there.
- **Acknowledgements and Help.** `AcknowledgementsView` and `HelpEngine`
  content: this is fine to keep native-only, but the web UI could link to it.
- **Media stream debug.** `MediaStreamDebug` is developer-only, so keep it
  native.

**Native-only on purpose (stays in the console, per the note in the web UI
settings):**

- The bot token (Replace…), and the invite bot link.
- App updates: Sparkle, Check Now…, the unattended toggle.
- Web UI sign-in, domain, certificate, DNS override, repair or reset.
- Recordings and Fast Start folders, plus Clear Cache.
- SwiftMesh role, ports, shared secret rotation, and worker offload. The web UI
  has "Work sharing" and "Add a node" groups, so decide which side owns each
  control so they don't diverge.
- Remote mode setup (`RemoteModeRootView`); the web UI has no matches for it.
- "Show SwiftBot as" (Dock or menu bar).

**Already covered by the web UI:**

Overview, Commands, Welcome Flow, Automations, Moderation, Announcer,
Game Tracker, Patchy, Sweep, Lookup (WikiBridge), Recordings, Analytics,
Rewind, Activity, SwiftMesh, Settings. The Settings view includes the
Apple Intelligence, Operator, Who can sign in, Integrations and Work sharing
groups. The native Apple Intelligence page appears to be covered by the web
settings group.

## Risks and things to keep in mind

- Cluster safety: the console must not offer controls on worker nodes that
  only the primary should run. Follow the rules in `Documentation/AI_CONTEXT.md`.
- Deep-link sign-in: a sign-in token valid for one use needs the same
  review that `AdminWebServerAuthTests` covers.
- `xcodebuild test` stops the live bot (see project notes), so run the console
  UI tests deliberately.
- Run `xcodegen` after adding the new console files.
