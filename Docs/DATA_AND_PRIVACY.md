# Data and Privacy

Atlas is local-first. Piped provides online video metadata and streams, but user library state is stored on device.

## Runtime settings

Settings are stored in UserDefaults, except the Piped instance URL is also mirrored into Keychain.

Important keys:

- `atlas.instanceURL` - selected Piped API URL.
- `feedMode` - Home feed mode.
- `atlas.hideShorts` - Hide Shorts toggle.
- `atlas.shortsLayout` - Home Shorts layout.
- `atlas.playerStyle` - fullscreen or embedded player.
- `atlas.player.statsForNerds` - diagnostics overlay.
- `atlas.sponsorBlock.enabled` - SponsorBlock master switch.
- `atlas.sponsorBlock.categories` - enabled SponsorBlock categories.
- `atlas.collaborators.resolveViaYouTube` - direct YouTube collaborator lookup opt-in.

## Piped instance storage

The selected instance is managed by `InstanceStore`.

Storage behavior:

- Load from UserDefaults and Keychain.
- Normalize by trimming whitespace, removing trailing slashes, and adding `https://` when no scheme is supplied.
- Accept HTTPS for hosted instances.
- Accept HTTP only for local/private hosts.
- Mirror valid values back to both stores.
- Clear invalid stored values only when a stored candidate was actually found and invalid.

Atlas does not include a default Piped instance. Online features throw a missing-instance error until the user configures one.

## SwiftData

SwiftData stores user library data:

- `SubscribedChannel` - local channel subscriptions.
- `HistoryEntry` - local watch history and resume position.
- `Playlist` and `PlaylistVideo` - local playlists and denormalized video snapshots.
- `DownloadedVideo` - metadata for completed media files.
- `Feedback` - Suggest More / Suggest Less ratings.
- `SearchEntry` - successful search history.
- `VideoSignalCacheEntry` - cached recommendation enrichment.
- `RecommendationProfileSnapshot` - cached recommender profile.

## Downloads

Downloaded media lives in:

```text
Application Support/Downloads
```

The directory and completed files are excluded from backups because media is large and re-downloadable.

`DownloadedVideo` stores file names instead of absolute URLs, because the app container path can change between launches.

Completed download files may include:

- `{videoID}.mp4` - media.
- `{videoID}.thumb` - cached poster.
- `{videoID}.captions.vtt` or `{videoID}.captions.ttml` - caption sidecar.

At launch, `DownloadManager` removes orphaned `.mp4`, `.video.mp4`, and `.audio.m4a` files that are not claimed by completed `DownloadedVideo` rows.

## Backups

Library -> Settings -> Backup & Data exports a JSON file.

The backup includes:

- History.
- Search history.
- Subscriptions.
- Playlists.
- Feedback.

Downloads are intentionally excluded. They are file-backed media and can be re-downloaded.

Import merges into the current store and avoids duplicates by stable keys such as video ID, channel ID, query, playlist name, or feedback video ID.

## Spotlight

Spotlight indexes:

- Completed downloads.
- Recent history rows.

Downloads win when a video exists in both downloads and history because the download result can play offline.

Spotlight entries are derived from local store data. They are rebuilt on launch and updated when downloads are added or removed.

## Direct network calls

Most online traffic goes to the selected Piped instance.

Direct youtube.com collaborator lookup is the exception. It is off by default and only runs when the user enables:

```text
Library -> Settings -> Privacy -> Resolve Collaborators via YouTube
```

When off, collaborator details are limited to what the Piped stream response exposes.

## SponsorBlock

SponsorBlock data is requested through the selected Piped instance. Atlas sends selected SponsorBlock category IDs to the instance and receives segment data for the current video.

Atlas does not auto-skip. It only shows a user-controlled skip button.

## Persistence recovery

If Atlas cannot open the on-disk SwiftData store, it launches with temporary in-memory storage and shows:

```text
Atlas could not open its saved library, so it started with temporary storage. Your existing on-device data was left untouched.
```

This protects existing data from being overwritten or silently deleted.
