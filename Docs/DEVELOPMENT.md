# Development

Atlas is a Swift 6, SwiftUI, SwiftData, iOS 26 app generated with XcodeGen.

## Requirements

- Xcode with iOS 26 SDK support.
- XcodeGen.
- Swift Package Manager.
- An iOS simulator such as iPhone 17 for tests.
- A Piped API instance configured at runtime for online app behavior.

## Project generation

`project.yml` is the source of truth. Do not hand-edit generated Xcode project files.

Regenerate the project after source file or target changes:

```sh
xcodegen generate
```

Open the project:

```sh
open Atlas.xcodeproj
```

The repository does not pin a personal Apple development team. Simulator builds
need no signing. For a device build, select your own team and use app and test
bundle identifiers registered to that team; the canonical `sh.cmf.atlas` IDs
are maintainer-owned. Do not commit personal team IDs or signing material.

## Build

CLI simulator build:

```sh
xcodebuild -project Atlas.xcodeproj -scheme Atlas \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## Test

Run app unit tests:

```sh
xcodebuild test -project Atlas.xcodeproj -scheme Atlas \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Run PipedKit tests:

```sh
swift test --package-path PipedKit
```

GitHub Actions runs project generation, strict formatting, both test suites,
and a clean Simulator build for pushes to `main` and pull requests.

Run the narrowest relevant test first. Broaden to app tests when changing shared behavior, playback, recommendations, downloads, persistence, or App Intents.

## Common test areas

Current test coverage includes:

- Recommendation ranking behavior.
- Download/playback stream selection.
- Comment timestamp parsing.
- Store cleanup behavior.
- PipedKit client/model behavior.

Add tests when changing:

- Stores or SwiftData write semantics.
- Recommendation signals or ranking.
- Stream selection.
- Playback fallback contracts.
- Download file handling.
- Piped decoding.
- Comment timestamp parsing.
- Backup import/export.

## Source layout

```text
Atlas/
  App/
  Components/
  Features/
  Models/
  Resources/
  Support/
AtlasTests/
PipedKit/
Docs/
```

Keep feature-only types in their feature folder. Move repeated UI to `Atlas/Components`. Keep non-UI helpers in `Atlas/Support` or the relevant model/store file.

## Coding guidelines

- Use Swift 6 conventions.
- Use four-space indentation.
- Prefer native SwiftUI and AVKit patterns before custom abstractions.
- Keep state ownership explicit.
- Keep SwiftUI views small enough to scan.
- Split large bodies into focused private views or helpers.
- Avoid drive-by refactors outside the requested scope.
- Keep generated project changes out of manual edits.

The repository's `.swift-format` file is the source of truth for mechanical
Swift formatting. It uses four-space indentation and a 120-column target. Use
Xcode's bundled formatter rather than installing a separate formatter version:

```sh
xcrun swift-format format --in-place --configuration .swift-format <files>
xcrun swift-format lint --recursive --parallel --strict \
  --configuration .swift-format \
  Atlas AtlasTests PipedKit/Sources PipedKit/Tests PipedKit/Package.swift
```

## Piped instance behavior

The app has no bundled default instance. Online development requires configuring one in:

```text
Library -> Settings -> Instance
```

Use HTTPS for hosted instances. HTTP is accepted only for local/private-network hosts.

## App data during development

Local library data is stored by SwiftData in the app container. Downloads are stored under Application Support/Downloads inside the app container.

Use Backup & Data from a healthy persistent store before changing bundle
identifiers or deleting app containers if local data matters. Do not export from
the temporary recovery session after a persistent-store open failure: that
session starts empty and is not a copy of the inaccessible store.

## Documentation maintenance

Update docs when changing:

- User-visible feature behavior.
- Settings.
- Persistent data fields.
- Backup format.
- Playback source selection.
- Piped endpoint contracts.
- Shortcut behavior.
- Build/test commands.
- Project structure.

If a README roadmap item conflicts with code, verify the code and update the docs instead of preserving stale roadmap text.
