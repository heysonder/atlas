# Repository Guidelines

## Project Organization

Keep the structure intentional. `project.yml` is the source of truth for generated Xcode project settings; do not hand-edit generated project files. App code lives under `Atlas/`, with feature screens grouped in `Atlas/Features/`, reusable SwiftUI components in `Atlas/Components/`, models and stores in `Atlas/Models/`, and non-UI helpers in `Atlas/Support/`.

Keep Piped API models, client code, and stream-selection logic inside `PipedKit/`. Keep changes scoped and avoid drive-by refactors unless they are required for the requested work.

## Build, Test, and Development Commands

```sh
xcodegen generate
```
Regenerate `Atlas.xcodeproj`.

```sh
open Atlas.xcodeproj
```
Open the app in Xcode.

```sh
xcodebuild -project Atlas.xcodeproj -scheme Atlas \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```
Verify the app builds from the CLI.

```sh
xcodebuild test -project Atlas.xcodeproj -scheme Atlas \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
Run app unit tests. Adjust the simulator name as needed.

```sh
swift test --package-path PipedKit
```
Run `PipedKit` package tests.

## Coding Style & Naming Conventions

Keep the codebase clean, native, and easy to change. Use Swift 6 conventions, four-space indentation, and standard SwiftUI patterns before custom abstractions. Prefer small views with clear names, move repeated UI to `Atlas/Components`, and keep feature-only types inside their feature folder. Split large SwiftUI bodies into focused private computed views or helper types. Keep state ownership explicit.

Follow Apple platform conventions for naming and structure. Types use `UpperCamelCase`; functions, properties, and enum cases use `lowerCamelCase`. Name tests after behavior, for example `testFiltersWatchedVideos()`.

## Testing Guidelines

Add or update tests when changing stores, recommendations, playback/download decisions, or Piped decoding. Use `AtlasTests/` for app tests and `PipedKit/Tests/` for package behavior. Run the narrowest relevant test first, then app tests for broad changes.

## Configuration & Security Tips

Atlas does not ship with a default Piped instance. Configure one at runtime in Profile settings. Keep bundle IDs, signing, ATS, and local-network usage text in `project.yml`.
