# Architecture

Atlas is a SwiftUI app with a small shared state model, a SwiftData local library, AVKit playback surfaces, and a separate local package for Piped API work.

## High-level map

```text
AtlasApp
  |
  +-- AppModel
  |     +-- selected Piped instance
  |     +-- current playback request
  |     +-- stream detail cache
  |     +-- session queue
  |     +-- runtime settings
  |
  +-- DownloadManager
  |     +-- active downloads
  |     +-- download tasks
  |
  +-- SwiftData ModelContainer
        +-- history, subscriptions, playlists, downloads,
            feedback, searches, recommendation caches
```

## App entry

`Atlas/App/AtlasApp.swift` creates:

- The shared URL cache for thumbnails and image prefetching.
- The SwiftData `ModelContainer`.
- `AppModel`.
- `DownloadManager`.
- App Intents dependencies.
- Spotlight reindexing after launch.
- An AVAudioSession configured for background playback and Picture in Picture.

If the persistent SwiftData store cannot open, Atlas creates a temporary in-memory container and shows a recovery message. It does not delete the on-disk store.

## Root navigation

`Atlas/App/RootView.swift` owns the top-level tab structure:

- Home -> `FeedView`.
- Library -> `ProfileView`.
- Search -> `SearchView`.

It also attaches the selected player surface:

- Fullscreen style uses `VideoPlayerPresenter` in the background.
- Embedded style presents `EmbeddedPlayerView` from `nowPlaying`.

RootView consumes pending intent actions from `AppModel` and handles Spotlight result taps.

## AppModel

`AppModel` is the app-wide observable state object.

It owns:

- `instanceURLString` for the selected Piped API instance.
- `nowPlaying` for the current `PlayRequest`.
- `queuedVideos` for the transient playback queue.
- `playerStyle`.
- `statsForNerdsEnabled`.
- `hideShorts`.
- `shortsLayout`.
- SponsorBlock settings.
- Selected tab state.
- Pending App Intent routing state.
- Stream detail cache and in-flight stream resolution.

It exposes a throwing `client` property. Online callers must handle the missing-instance error when no Piped instance is configured.

## State and persistence split

Atlas keeps transient state in `AppModel` and durable local data in SwiftData.

Transient:

- Current playback request.
- Session queue.
- Stream detail cache.
- In-flight stream resolution.
- UI routing requests from intents.
- Active downloads.

Persisted:

- Piped instance URL, mirrored in UserDefaults and Keychain.
- Settings values in UserDefaults.
- SwiftData local library rows.
- Download media files in Application Support.
- Spotlight index entries derived from downloads and history.

## SwiftData schema

The model schema lives in `Atlas/Models/AtlasModelSchema.swift` and includes:

- `SubscribedChannel`.
- `HistoryEntry`.
- `Playlist`.
- `PlaylistVideo`.
- `DownloadedVideo`.
- `Feedback`.
- `SearchEntry`.
- `VideoSignalCacheEntry`.
- `RecommendationProfileSnapshot`.

Store helper types such as `PlaybackHistoryStore`, `PlaylistStore`, `SubscriptionStore`, `SearchHistoryStore`, `FeedbackStore`, and `BackupStore` centralize reads/writes so UI flows do not duplicate persistence rules.

## PipedKit boundary

`PipedKit` is the API and decoding boundary. It contains:

- `PipedClient`.
- Codable response models.
- Piped error mapping.
- Stream and subtitle helpers.
- ID parsing.
- HTML-to-plain-text cleanup.

The app imports `PipedKit` for network models and client calls, but playback-specific AVFoundation construction stays in `Atlas/Features/Player/`.

## Feature folders

`Atlas/Features/` is grouped by user-facing workflow:

- `Feed` - Home feed loading, personalization entrypoint, subscriptions aggregation.
- `Search` - search UI, suggestions, pagination, search history.
- `Channels` - channel list and detail pages.
- `Player` - fullscreen and embedded players, stream builder, info sheet, comments, SponsorBlock, captions, diagnostics.
- `Downloads` - offline media storage and UI.
- `Playlists` - local playlist management.
- `Profile` - Library, settings, instance, backup, SponsorBlock, history.
- `Recommendations` - local recommendation profile and ranking.
- `Intents` - Siri, Shortcuts, Spotlight, visible video registry.

## Components and support

`Atlas/Components/` contains reusable UI:

- Video rows and grouped video lists.
- Thumbnail/avatar rendering.
- Context menus.
- Queue menu items.
- Creator controls.
- Layout helpers.
- Error and empty states.

`Atlas/Support/` contains non-UI or lightly UI-adjacent helpers:

- Formatting.
- Load phases.
- Thumbnail prefetching.
- Optional collaborator lookup.

## Generated project rule

`project.yml` is the source of truth. `Atlas.xcodeproj` is generated and should not be hand-edited.

Run:

```sh
xcodegen generate
```

after adding, moving, or deleting source files that the generated project needs to know about.
