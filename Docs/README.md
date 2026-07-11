# Atlas Docs

Atlas is a native iOS YouTube client built on Piped. This docs folder explains what the app does, how the main flows work, where the behavior lives in the codebase, and how to build and debug it.

## Start here

| Document | Use it for |
| --- | --- |
| [FEATURES.md](FEATURES.md) | Product behavior by tab and feature area. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | App structure, state ownership, SwiftData, and PipedKit boundaries. |
| [PLAYBACK.md](PLAYBACK.md) | Stream resolution, AVPlayer setup, fallback behavior, queueing, SponsorBlock, captions, and player surfaces. |
| [RECOMMENDATIONS.md](RECOMMENDATIONS.md) | Home feed modes and the on-device For You ranking system. |
| [DATA_AND_PRIVACY.md](DATA_AND_PRIVACY.md) | Persisted data, downloads, backups, instance storage, privacy-sensitive network calls, and recovery behavior. |
| [SHORTCUTS_AND_SPOTLIGHT.md](SHORTCUTS_AND_SPOTLIGHT.md) | Siri, App Shortcuts, App Entities, visible-result resolution, and Spotlight indexing. |
| [PIPEDKIT.md](PIPEDKIT.md) | Piped API client, models, stream-selection helpers, comments, SponsorBlock, and error handling. |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Setup, build/test commands, generated project rules, and development workflow. |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common runtime, playback, download, data, and build failures. |

## Project facts

- Platform: iOS 26, Swift 6, SwiftUI, SwiftData, AVKit.
- Project generator: XcodeGen. `project.yml` is the source of truth.
- App target: `Atlas`.
- Test target: `AtlasTests`.
- Local package: `PipedKit`.
- Bundle identifier: `sh.cmf.atlas`.
- Runtime requirement: the user must configure a Piped API instance in Library -> Settings -> Instance. Atlas does not ship with a default instance.

## Source map

- `Atlas/App/` - app entry point, root tab structure, app-wide state, instance storage.
- `Atlas/Features/` - feature screens and workflows.
- `Atlas/Components/` - shared SwiftUI UI components.
- `Atlas/Models/` - SwiftData models, stores, backup, feed settings, and local app data types.
- `Atlas/Support/` - non-UI helpers such as formatting, loading state, thumbnail prefetching, and collaborator lookup.
- `PipedKit/` - Piped API client, network destination policy, Codable response models, stream helpers, ID parsing, and HTML text cleanup.
- `AtlasTests/` - app-level behavior tests.
- `Docs/Screenshots/` - screenshots used by README/docs.

## Working rule

Update docs when a feature behavior, public setting, data model, Piped contract, playback strategy, or build/test command changes. Keep docs grounded in shipped behavior and call out future work separately.
