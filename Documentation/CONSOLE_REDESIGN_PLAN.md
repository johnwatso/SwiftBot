# SwiftBot Console Redesign — Web UI First

Status: first console opt-in and web deep links implemented (2026-10-03).
Native feature views remain available in the default layout. Web parity gaps
below are audited only; no missing web features were added.

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

**Verified web parity audit (2026-10-03):**

References use repository-relative `file:line` locations. A missing result refers
both to the native capability and the closest web surface inspected; absence is
not inferred from navigation labels alone.

| Capability | Result | Evidence and remaining work |
| --- | --- | --- |
| Automation simulation | Missing | `Sources/SwiftBot/AutomationSimulationResultView.swift:10` renders trigger/filter/step traces, fed by `AutomationRuleEditor.swift:1400`. `Sources/SwiftBot/Resources/admin/index.html:9769` and `:9955` provide edit/save, triggers, filters and steps, but no sample event execution or simulation trace. Sweep's Try run (`:12071`) is a separate feature, not automation simulation. |
| Bot permissions check | Missing | `Sources/SwiftBot/BotPermissionsCheckView.swift:139` inspects guild permissions using the catalog at `:25`. Web Settings (`Sources/SwiftBot/Resources/admin/index.html:14152`) provides an invite link, not effective-permissions inspection or per-guild diagnostics. |
| Rule editor / variable autocomplete | Partly covered | `Sources/SwiftBot/AutomationRuleEditor.swift:1042` uses `VariableAutocompleteField`; `Sources/SwiftBot/VariableAutocompleteField.swift:53` filters suggestions for the current trigger and partial brace token. The web editor (`Sources/SwiftBot/Resources/admin/index.html:9955`, `:10250`, `:10315`) supports triggers, filters, steps, templates and AI prompts, but its plain textareas and variable help (`:10337`) have no equivalent trigger-aware autocomplete. |
| User timezones | Covered | `Sources/SwiftBot/UserTimezonesView.swift:195` manages member-to-IANA-zone mappings. Web Settings opens the editor at `Sources/SwiftBot/Resources/admin/index.html:14235`, with member selection, IANA validation, add/remove and config saving. |
| Game provider configuration | Partly covered | `Sources/SwiftBot/GameProviderConfigurationSheet.swift:37` and `:136` provide credentials plus advanced Base URL and Rank Endpoint fields. Web Game Tracker's provider editor (`Sources/SwiftBot/Resources/admin/index.html:11404`) supports reveal, validation, replacement and removal of Keychain credentials, but no advanced endpoint editing. |
| SwiftMiner pairing | Partly covered | `Sources/SwiftBot/SwiftMinerPairingSheet.swift:145` opens the companion pairing flow; `:156` accepts pairing tokens and the sheet can disconnect. Web Settings (`Sources/SwiftBot/Resources/admin/index.html:14170`) only toggles an already-paired integration and explicitly directs initial pairing to the Mac app. |
| Remote mode | Missing, intentionally native | `Sources/SwiftBot/RemoteModeRootView.swift:74` provides the remote dashboard and configuration; web navigation (`Sources/SwiftBot/Resources/admin/index.html:6110`) has no remote host/provider setup. Keep this native: it must work before a local web server exists. |

Acknowledgements/Help and media-stream debugging remain native by design.

**SwiftMesh ownership:**

The console owns this Mac's lifecycle, role, addresses, listen/outbound ports,
shared secret rotation, join-code acceptance and connection diagnostics. Reuse
`Sources/SwiftBot/MeshPreferencesView.swift:108` (role/configuration), `:147`
(join), `:240` (join-code generation/rotation), and `:86` (offload binding).
The browser is the main cluster administration surface: topology, monitoring,
Primary work-sharing policy (`Sources/SwiftBot/Resources/admin/index.html:15616`)
and Primary join-code distribution (`:15621`). These shared controls use existing
AppModel/API state; neither side owns a separate copy. The browser already edits
role/configuration (`:15626`), so it is inaccurate to call all mesh controls
native-only. Retain the native controls for local recovery and initial setup;
do not introduce a divergent policy or credentials store. Existing Primary-only
mesh guards remain in the reused preferences, and console voice/AI/gateway
controls are disabled on Worker and Failover nodes.

**Native-only on purpose (stays in the console, per the note in the web UI
settings):**

- The bot token (Replace…), and the invite bot link.
- App updates: Sparkle, Check Now…, the unattended toggle.
- Web UI sign-in, domain, certificate, DNS override, repair or reset.
- Recordings and Fast Start folders, plus Clear Cache.
- SwiftMesh local recovery and secret rotation stay native. Role/configuration,
  work sharing and join-code distribution are shared with the browser as above.
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


## Implemented in the first opt-in pass

- `ConsoleItem.sidebarSections` defines all eleven destinations exactly once.
  `ConsoleRootView` uses a native split view and grouped forms, reusing existing
  preferences content through `SettingsForm`'s console environment. Existing
  feature pages and Preferences remain available. The local `Use console layout`
  preference is off by default and can be toggled in General settings.
- This Mac exposes Overview/Settings/Storage; Access reuses token and sign-in
  controls; Logs embeds the existing live activity/audit feed and diagnostic
  export; Alerts uses `OverviewHealthReport.attention`, including its sidebar badge.
- Service switches use existing state: gateway/mesh runtime lifecycle, web-server
  enablement, voice connection, recording source enablement, DM AI replies and
  automatic update checks. There is no existing universal recordings or model
  power switch. Help text identifies the actual scope, and recording monitoring
  is disabled until a folder exists. The mesh lifecycle switch is unavailable in
  Standalone mode; role setup stays in the reused mesh preferences.
- Health shows known runtime status and the existing gateway/mesh start date.
  No restart dates are fabricated. Voice device selection has no existing host
  preference; the console reports the configured voice/channel and links to the
  browser instead. Existing preference form content is embedded with its original
  labels and logic, rather than rewriting the native features for this pass.
- All sixteen web destinations have `#/view` routes, and Settings groups have
  `#/settings/general`, `apple-intelligence`, `features`, `integrations`,
  `who-can-sign-in`, `operator`, and `about-this-server` anchors. Explicit routes
  win after sign-in; an empty/invalid hash preserves the configured start page on
  initial load. Navigation records hash history and Back/Forward restore views.
- `AppModel.openWebUI(route:)` uses the current resolved address, replacing only
  its fragment. Disabled web UI produces visible feedback and opens no URL.
  The old launch controls had only disabled-button behavior, not a shared error
  presentation, so an explanatory alert was added for this helper.
- Preview fixtures/server require no edits: URL fragments stay in the browser.

## Follow-ups and validation limits

- Add a short-lived, single-use sign-in handoff token separately, with expiry,
  replay protection, scope and authentication tests. No token was added here.
- Close the audited web gaps before removing any native feature views.
- Native runtime visual QA and service-toggle exercise remain pending: the app
  was built but not launched, to preserve the live Debug bot. Build validation
  passed with existing repository warnings. Browser preview verified all sixteen
  view routes, the Apple Intelligence anchor, and Back/Forward navigation.
- Added `ConsoleSidebarLayoutTests`. With explicit permission, run it alongside
  `SidebarLayoutTests`, `AdminWebCopyTests`, and `AdminWebServerAuthTests` using
  Xcode tooling. No `xcodebuild test` was run because it stops the live Debug bot.
- `AI_CONTEXT.md` references root `DESIGN.md` and `ROADMAP.md`; their actual
  paths are under `Documentation/`. Its old Rule sketch (optional trigger /
  actions) also differs from the current nonoptional trigger / steps model.
  This pass follows the current code and leaves rule behavior unchanged.
- The root's onboarding and remote-mode precedence is preserved even when the
  local console preference is on. Remote nodes keep their existing dashboard;
  they are never handed local host-service switches.


## Modern native console polish (2026-10-03)

Inspected the running app through native navigation without changing services.
The first pass clipped the toolbar title inside a glass capsule, repeated service
switches/status/actions, and nested the activity list inside a scrolling Form.
The revision removes the custom toolbar title, uses native window chrome for the
console, and keeps the classic dashboard's existing chrome when that layout is
selected. Page identity now sits above the form, the overview has a compact
four-column metric strip and a browser handoff row, and service switches use
specific labels where they control DM replies, folder monitoring or update
checks. Model health is independent of whether DM replies are enabled.

Logs fills its detail pane and keeps filters on one horizontal line; the original
activity view, search, filtering and audit behavior are reused. The Admin Web UI
preferences omit their duplicate enable and launch controls only when embedded
in the console. This Mac includes existing hardware metadata. Console windows
can be narrower while classic/remote window sizing remains unchanged.

The revised Debug build passes. Runtime inspection of the rebuilt screens awaits
a relaunch decision because the currently running Debug app hosts the live bot.
No Xcode tests, service changes, version changes or release changes were made.
