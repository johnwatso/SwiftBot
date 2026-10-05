# SwiftBot Console Redesign

Updated 2026-10-05. This document describes the current implementation and
remaining work; the original Server.app proposal is superseded.

## Approved direction

The native Overview is the visual baseline: large system headers, generous
spacing, quiet glass surfaces, rounded section panels, and service cards.
Apply that language across the native console. See `DESIGN.md`.

The Mac app manages the host and its services. Bot feature configuration is
available in the admin Web Interface. Keep onboarding native because it must
work before the web server exists.

## Implemented

- Native sidebar: Overview, Discord, Web Interface, SwiftMesh, Integrations,
  Recordings, Activity.
- Console Overview with host identity, service health, quick actions, and system
  facts; the classic dashboard remains available from the overflow menu.
- Web Interface, SwiftMesh configuration, and Integrations use console forms.
  App Settings retains General and Updates.
- Discord has a service summary, connection controls, token management sheet,
  auto-connect settings, invites and permissions, known servers, and
  connection diagnostics. Overview links to it; General retains app preferences.
- Activity uses the shared console header and surface, with export, copy, clear,
  search, topic/severity controls, and an actionable empty state.
- Recordings manages this Mac's source folders and Fast Start copies, with
  folder availability, scan feedback, and an indexed-library summary. Browsing
  and playback remain in the Web Interface. General no longer contains folders;
  Fail Over and Worker nodes can still edit their local folders.
- Recording folder enable switches sit on the trailing edge. The managed
  Exports source is temporarily hidden while exporting is unfinished; it is
  neither indexed nor automatically added. Existing files/configuration remain.
- SwiftMesh Status and Settings share one console page and scrolling viewport,
  with node identity, configured/runtime roles, term, and membership in its
  summary. Health & Work uses four equal-width cards matching Overview’s
  Services section, with a 2 × 2 fallback on narrower windows. Single-node maps
  are compact and diagnostic panels stack when needed.
- The split-view detail is bounded to its actual viewport so a destination’s
  ideal content height cannot shift the sidebar. The app window defers its
  minimum size to RootView instead of imposing a second, larger minimum.
- Headers and Overview diagnostics adapt to narrower windows. Local console
  minimum size is 1040 × 700; onboarding retains its limits.
- Web status shows the Website hostname when a tunnel is configured, otherwise
  Local Address, alongside Local Transport, Public Access, and HTTPS Policy, including an explanation of Cloudflare TLS termination.
- Warning details wrap, review actions have service-specific accessibility
  labels, and the connection-test action reflects its existing cooldown.

- Cloudflare API token entry, SwiftMesh shared-secret management, and the local
  fallback password use sheets. Main settings show status and an action;
  secret edits stay in sheet drafts until saved. Cloudflare verification and
  the existing secret-rotation confirmation remain in place.

## Remaining work

- Remote Control mode was removed on 2026-10-06; the WebUI is how you manage
  SwiftBot from another device. Onboarding uses the shared icon tiles, system
  title type and console surfaces; it still needs a visual check.
- Validate the updated console visually in light/dark mode, Increase Contrast,
  Reduce Transparency, VoiceOver, and the narrower window size.
- Before deleting retained native feature views, verify full web workflows:
  automation simulation, variable insertion, permissions, user timezones,
  game-provider setup, and SwiftMiner pairing. Presence of a web page alone
  does not establish parity.
- Review browser handoff URLs and sign-in continuity. Keep any authentication
  changes separate from visual work and covered by auth tests.

## Guardrails

Preserve cluster output gates, failover restrictions, and all existing
confirmation flows. Do not change secrets, connectivity, release metadata, or
service behavior as part of a styling pass. Build with Xcode tooling. Hosted
XCTest launches the app, so use it deliberately around a live bot.
