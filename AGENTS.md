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
- `CURRENT_PROJECT_VERSION` should not be changed casually. Only update it when the requested work includes release/version/build preparation.
- When version metadata changes, keep `project.yml` and `SwiftBot.xcodeproj/project.pbxproj` aligned.
- If release metadata is touched, also verify related Sparkle/appcast files under `docs/`.

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

## Project Generation Rules

- `project.yml` is the source of truth for generated Xcode settings.
- If you change build settings in the generated project, mirror them in `project.yml` unless there is a very specific reason not to.
- Avoid committing unrelated XcodeGen drift.

## Coordination

- Use `AI_CONTEXT.md` for architecture, file ownership, cluster safety rules, and UI rules.
- If guidance in this file and `AI_CONTEXT.md` ever appear to conflict, follow the repo reality and preserve existing behavior, then document the inconsistency in your final note.
