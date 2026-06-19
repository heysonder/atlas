# Repository Guidelines

## Project Structure & Module Organization

Atlas is a native SwiftUI iOS app targeting iOS 26. `project.yml` is the source of truth for the generated Xcode project; regenerate `Atlas.xcodeproj` after changing project settings or target membership.

- `Atlas/App/`: app entry point, root view, shared app model, and instance storage.
- `Atlas/Features/`: feature screens grouped by domain, such as `Player`, `Feed`, `Search`, `Downloads`, `Playlists`, and `Profile`.
- `Atlas/Components/`: reusable SwiftUI views shared across features.
- `Atlas/Models/`: SwiftData models and local stores.
- `Atlas/Support/`: non-UI helpers and formatting utilities.
- `Atlas/Resources/`: `Info.plist` and asset catalogs.
- `AtlasTests/`: app unit tests.
- `PipedKit/`: local Swift package for Piped API models, client code, and stream-selection logic.

## Build, Test, and Development Commands

```sh
xcodegen generate
```
Regenerates `Atlas.xcodeproj` from `project.yml`.

```sh
open Atlas.xcodeproj
```
Opens the app in Xcode for simulator or device development.

```sh
xcodebuild -project Atlas.xcodeproj -scheme Atlas \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```
Builds the app from the CLI without requiring local signing.

```sh
xcodebuild test -project Atlas.xcodeproj -scheme Atlas \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
Runs the app unit test target. Adjust the simulator name to one installed locally.

```sh
swift test --package-path PipedKit
```
Runs the package tests for `PipedKit`.

## Coding Style & Naming Conventions

Use Swift 6 conventions with four-space indentation. Prefer small, domain-named SwiftUI views and keep reusable UI in `Atlas/Components`. Keep feature-specific types inside their feature folder unless used across multiple domains. Name tests after the behavior under test, for example `RecommendationEngineTests` or `testFiltersWatchedVideos()`.

## Testing Guidelines

Add or update tests when changing store logic, recommendation behavior, playback/download decisions, or Piped decoding. Use `AtlasTests/` for app-level tests and `PipedKit/Tests/` for package behavior. Run the narrowest relevant test command first, then the full app test command before submitting broad changes.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit-style subjects, such as `fix(player): let AVKit own now playing controls` and `feat(library): add adaptive grid layouts`. Keep commits scoped and imperative.

Pull requests should include a concise behavior summary, tests run, linked issue when applicable, and screenshots or recordings for UI changes. Note any required `xcodegen generate` or signing-related setup.

## Configuration & Security Tips

Atlas does not ship with a default Piped instance. Configure one at runtime in Profile settings. Keep bundle IDs, signing team, ATS policy, and local-network usage text in `project.yml` rather than editing generated project files directly.
