# Data and Privacy

Atlas is local-first. Piped provides online video metadata and streams, but user library state is stored on device.

## Runtime settings

Settings are stored in UserDefaults. The Piped instance URL is mirrored into
Keychain as well as UserDefaults so app and headless App Intent paths share the
same selected instance. The Keychain item uses
`AfterFirstUnlockThisDeviceOnly`: it becomes available after the device's first
unlock and does not migrate to a different device from a backup. The UserDefaults
copy is not secret storage.

The app's bundled privacy manifest declares app-only UserDefaults access under
Apple's `CA92.1` required reason. It also declares disk-space access under
`E174.1`, which Atlas uses to avoid starting downloads that cannot fit. Atlas
declares no tracking domains and no data collection in that manifest.

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

Atlas requests backup exclusion for the directory and completed files because
media is large and re-downloadable. That resource-value update is best-effort;
failure does not make a completed download unusable.

`DownloadedVideo` stores file names instead of absolute URLs, because the app container path can change between launches.

Completed download files may include:

- `{videoID}.mp4` - media.
- `{videoID}.thumb` - cached poster.
- `{videoID}.captions.vtt` or `{videoID}.captions.ttml` - caption sidecar.

At launch, `DownloadManager` best-effort removes recognized orphaned download
artifacts that are not claimed by completed `DownloadedVideo` rows. A file-system
error can leave an orphan in place for a later cleanup attempt.

## Backups

Library -> Settings -> Backup & Data exports a JSON file.

The export is an ordinary, unencrypted JSON file written to Atlas's temporary
directory and passed to the system share sheet. Its final destination and
protection depend on the share target the user chooses. Treat it as sensitive:
it contains viewing and interest data, and Atlas does not add backup encryption.

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

## System surfaces and transient caches

Atlas exposes selected local or derived data outside its own screens:

- Spotlight indexes recent history and completed downloads, including titles,
  uploader names, and poster references.
- App Intents and Shortcuts can query downloads, recent history, playlists, and
  videos recently placed in the in-memory visible-video registry.
- Now Playing surfaces can show the active video's title, creator, artwork, and
  playback state on the Lock Screen, Control Center, CarPlay, and connected media
  controls managed by the system.

Atlas also keeps transient performance data: the session playback queue,
stream-detail and recommendation working caches, in-flight request state, an
in-memory decoded-image cache, and a shared URL cache that may use memory and disk.
These are not library sync services, but cached network responses may persist
until normal system or app cache eviction.

## Network destinations

Atlas sends API requests to the selected Piped instance. This includes search
terms and video or channel identifiers used to fetch feeds, recommendations,
stream metadata, comments, and SponsorBlock segments. Recommendation ranking and
the library database remain local, but identifiers and queries derived from local
signals are sent when Atlas asks Piped for candidates.

Piped responses contain media, HLS, thumbnail/avatar, and caption URLs. Atlas
contacts those referenced hosts directly for playback, images, prefetching, Now
Playing artwork, and downloads. A self-hosted Piped instance therefore does not
proxy all runtime traffic.

Direct youtube.com collaborator lookup is another optional destination. It is
off by default and only runs when the user enables:

```text
Library -> Settings -> Privacy -> Resolve Collaborators via YouTube
```

When off, collaborator details are limited to what the Piped stream response exposes.

## SponsorBlock

SponsorBlock data is requested through the selected Piped instance. Atlas sends selected SponsorBlock category IDs to the instance and receives segment data for the current video.

Atlas does not auto-skip. It only shows a user-controlled skip button.

## Diagnostics

Playback and download diagnostics use Apple's unified `Logger`. Video IDs are
marked private and hash-masked. Bounded event/source labels, numeric playback or
byte measurements, and error domains/codes are logged as public to keep failure
reports actionable. Atlas does not intentionally log full media URLs, search
queries, titles, or backup contents.

## Persistence recovery

If Atlas cannot open the on-disk SwiftData store, it launches with temporary in-memory storage and shows:

```text
Atlas could not open its saved library, so it started with temporary storage. Your existing on-device data was left untouched.
```

This protects existing data from being overwritten or silently deleted.

The temporary store starts empty; it is not a recovered copy of the inaccessible
store. Do not export from that recovery session expecting the old library. Keep
the app container intact and recover from a JSON backup made while the persistent
store was healthy, or diagnose the original store before attempting migration.
