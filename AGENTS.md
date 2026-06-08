# SwiftBot Agent Notes

Read `AI_CONTEXT.md` first. It is the main architecture and workflow reference for AI agents working in this repo.

This file exists to capture the practical guardrails that agents are most likely to miss: build system boundaries, project generation, versioning, and release metadata discipline.

## Project Shape

- SwiftBot is a native macOS Xcode app built with SwiftUI.
- The app project is generated from `project.yml` using XcodeGen.
- This repo also contains one nested Swift package at `Sources/UpdateEngine`.
- Do not convert the main app into a Swift package.
- Do not introduce a repo-root `Package.swift`.
- Do not move app files into a package-style layout.

## Build and Test

For the main app, use Xcode tooling:

```sh
xcodebuild -project SwiftBot.xcodeproj -scheme SwiftBot -configuration Debug build
xcodebuild -project SwiftBot.xcodeproj -scheme SwiftBot -configuration Debug test
```

Run `xcodegen` after editing `project.yml`:

```sh
xcodegen
```

For the nested UpdateEngine package only, SwiftPM commands are valid inside `Sources/UpdateEngine` when that package is the thing being changed:

```sh
cd Sources/UpdateEngine
swift test
```

Do not use `swift build` or `swift test` as a substitute for validating the app target.

## Scope Discipline

- Keep changes scoped to the user’s request.
- Prefer modifying the relevant SwiftUI view, model, or service directly instead of refactoring unrelated systems.
- Do not introduce new modules, packages, or architectural layers unless the user explicitly asks for that level of change.
- Follow existing Apple-platform patterns in this repo. Avoid web-style UI abstractions and avoid external UI frameworks.

## Versioning

- `MARKETING_VERSION` is user-directed. Do not bump it unless the user explicitly asks.
- `CURRENT_PROJECT_VERSION` is timestamp-based. Update it whenever release/version/build preparation is part of the requested work. Use the local project time at the moment of the change, formatted as `yyyyMMddHH` (example: `2026050813` means 2026 May 8 at 1pm).
- Treat ShipHook/publish/release-prep work like SwiftMiner: refresh the build number before shipping, even when the marketing version stays the same.
- When version metadata changes, keep `project.yml` and `SwiftBot.xcodeproj/project.pbxproj` aligned.
- If release metadata is touched, also verify related Sparkle/appcast files under `docs/`:
  - `sparkle:shortVersionString` should match `MARKETING_VERSION`.
  - `sparkle:version` should match the generated `CURRENT_PROJECT_VERSION` timestamp.
  - Any visible build references in release notes should match the generated build number.

## Sparkle and Release Metadata

Treat these as release-critical whenever touched:

- `project.yml`
- `SwiftBot.xcodeproj/project.pbxproj`
- `docs/appcast.xml`
- `docs/release-notes/*`

Do not break:

- `SUFeedURL`
- `SUPublicEDKey`
- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`
- appcast version/release-note links

If you edit release metadata, build the app and verify the resulting Info.plist values before calling the work done.

## ShipHook API

ShipHook is the service used for SwiftBot publishing and release operations. Treat ShipHook work as release/publish work, including the versioning and Sparkle metadata discipline described above.

ShipHook API base URL:

- `https://shiphook.thehewetts.co.nz/api`

Reference:

- `https://github.com/maxhewett/ShipHook/blob/main/API.md`

Use `/api` in the web UI for interactive docs, token generation, and try-it requests. Automation should authenticate with bearer tokens:

```sh
curl -H 'Authorization: Bearer shiphook_xxx' https://shiphook.thehewetts.co.nz/api/v1/status
```

Important endpoints:

- `GET /api/v1/status` returns the dashboard snapshot; add `?id=REPOSITORY_ID` for one repository runtime status.
- `GET /api/v1/repositories` returns configured repositories, runtime state, recent builds, and recent releases.
- `GET /api/v1/repository?id=REPOSITORY_ID` returns one repository snapshot.
- `GET /api/v1/log?id=REPOSITORY_ID&tail=200` returns a JSON log tail; `tail` is clamped to `1...2000`.
- `POST /api/v1/check` checks for work and may start a build when a repository has a buildable update.
- `POST /api/v1/build` is an alias for `check`.
- `POST /api/v1/pull` pulls the configured branch locally without publishing.
- `POST /api/v1/reclone` deletes and reclones the configured local checkout; requires `repositoryID`.
- `POST /api/v1/restart` requests a soft restart of the ShipHook agent.
- `POST /api/v1/hard-restart` schedules a recovery restart for wedged agents; use only when ordinary endpoints do not respond.
- `GET /api/v1/files/list?repositoryID=REPOSITORY_ID&path=Sources` lists visible checkout files, limited to 200 entries.
- `GET /api/v1/files/read?repositoryID=REPOSITORY_ID&path=README.md` reads a UTF-8 text file from the checkout.

Token management endpoints are `POST /api/auth/tokens` and `POST /api/auth/tokens/revoke`. Tokens are stored hashed and are only shown once. ShipHook records token, build/check, pull, reclone, restart, and hard-restart actions in the web UI audit log.

## Project Generation Rules

- `project.yml` is the source of truth for generated Xcode settings.
- If you change build settings in the generated project, mirror them in `project.yml` unless there is a very specific reason not to.
- Avoid committing unrelated XcodeGen drift.

## Coordination

- Use `AI_CONTEXT.md` for architecture, file ownership, cluster safety rules, and UI rules.
- If guidance in this file and `AI_CONTEXT.md` ever appear to conflict, follow the repo reality and preserve existing behavior, then document the inconsistency in your final note.
