# Shortcuts and Spotlight

Atlas integrates with App Intents, App Shortcuts, App Entities, a transient
visible-video registry, and Core Spotlight.

## Launch wiring

`AtlasApp` injects:

- `ModelContainer` into `IntentDataStore`.
- `AppModel` into `AppDependencyManager`.
- `DownloadManager` into `AppDependencyManager`.

It also schedules a Spotlight reindex shortly after launch.

## Intent routing

Navigation intents do not directly manipulate SwiftUI navigation stacks. They set deferred routing values on `AppModel`, then `RootView` and `ProfileView` consume those values once the UI is alive.

Routing values:

- `AtlasIntentAction.search(String)`.
- `AtlasIntentAction.resumeWatching`.
- `AtlasIntentAction.forYou`.
- `AtlasIntentAction.openDownloads`.
- `LibraryTarget.downloads`.
- `LibraryTarget.history`.
- `LibraryTarget.playlists`.

This handles both cold launch and warm app cases.

## Exposed shortcuts

`AtlasShortcuts` exposes:

- Search.
- Resume Watching.
- Open For You.
- Open Downloads.
- Play Video.
- Download Video.
- Add to Playlist.
- Find Videos.

Search and navigation shortcuts open the app. Find Videos returns `VideoEntity` values for chained Shortcuts workflows.

## VideoEntity

`VideoEntity` represents a playable video for Siri and Shortcuts.

It carries:

- YouTube video ID.
- Title.
- Uploader.
- Thumbnail URL.
- Optional local download file name.

Entity resolution can use:

- Currently visible videos.
- Completed downloads.
- Piped search results.

When a video is downloaded, Play Video prefers the local file if it still exists.

## Visible videos

Feed, Search, and Channel lists call `.onScreenVideos(videos)`.

That records visible stream items into the in-memory `VisibleVideoRegistry`,
capped at 250 IDs. The registry helps App Intent entity queries resolve video
identifiers already surfaced by Atlas without another network fetch. It is not
an iOS semantic-index or on-screen-awareness integration.

## PlaylistEntity

`PlaylistEntity` represents local playlists.

It supports:

- Resolving by UUID.
- Matching spoken names.
- Suggested existing playlists.
- Create-on-demand placeholders.

If the user asks to add a video to a playlist name that does not exist, Shortcuts can create the playlist before adding the video.

## IntentDataStore

`IntentDataStore` is the main-actor bridge from App Intents into Atlas data.

When the app is running, it uses the injected container and app model. When an intent runs headless, it can create its own `ModelContainer` over the same schema and read the selected instance from `InstanceStore`.

It provides:

- Downloads lookup.
- Recent history lookup.
- Most recent watch lookup.
- Piped video search.
- Playlist lookup.
- Add-to-playlist behavior.

## Spotlight

`SpotlightIndexer` publishes downloads and watch history to Core Spotlight.

Domains:

- `sh.cmf.atlas.downloads`.
- `sh.cmf.atlas.history`.

Item IDs are namespaced as:

```text
video:{videoID}
```

When the user taps a Spotlight result, RootView receives the searchable item user activity, extracts the video ID, and plays the downloaded copy if present. Otherwise, it streams the video through the configured Piped instance.

## Reindexing

On launch, Atlas:

- Deletes Atlas's current and known legacy Spotlight domains.
- Indexes completed downloads.
- Indexes recent history rows not already covered by downloads.

The delete completes before indexing begins, so the local stores are
authoritative and stale entries do not survive a rebuild.

Completed downloads are indexed with local poster URLs when available so results can show artwork offline.
