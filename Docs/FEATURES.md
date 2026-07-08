# Features

Atlas is organized around three tabs: Home, Library, and Search. Most online features require a configured Piped API instance. Local library features such as history, playlists, and completed downloads use SwiftData and local files.

## Home

Home is implemented by `Atlas/Features/Feed/FeedView.swift`.

Home has three feed modes:

- Subscriptions - newest uploads from channels the user follows.
- For You - Related - candidates based on Piped related videos from local watch signals.
- For You - Personalized - an on-device topic match that learns from watches, searches, saved videos, subscriptions, and Suggest More / Suggest Less feedback.

The feed hides videos that count as watched. A video counts as watched when Atlas knows its duration and at least 80 percent has been seen. This keeps brief accidental opens from removing videos from Home.

When there are no subscriptions, or when a subscription feed returns no usable videos, Atlas falls back to regional trending content. The region comes from the current locale, defaulting to `US`.

## Shorts

Shorts behavior is controlled in Library -> Settings -> Content.

- Hide Shorts removes Shorts from Home, Search, and Channel pages.
- In feed shows Shorts mixed into the Home feed, paired two per row.
- Carousel collects Shorts into a horizontal shelf near the top of Home.

Search and Channel pages always use inline or channel-specific layouts rather than the Home-only layout picker.

## Search

Search is implemented by `Atlas/Features/Search/SearchView.swift`.

Search supports:

- YouTube video and channel search through the selected Piped instance.
- Recent search history.
- Local history suggestions.
- Remote suggestions after a short debounce.
- Paginated results.
- Channel result navigation.
- Video playback from result rows.

Successful searches are recorded locally and become signals for the personalized For You feed. Failed searches are not recorded.

Re-tapping the Search tab clears the current field and refocuses search input.

## Channels

Channel list and detail screens are implemented in `Atlas/Features/Channels/`.

The Library -> Channels list shows locally subscribed channels. Channel detail pages fetch Piped channel metadata, banner, avatar, subscriber count, uploads, Shorts tab data, and pagination tokens.

Channel pages show watched badges instead of hiding watched videos. This is different from Home because a channel page is expected to show the full catalog.

The subscribe button writes a `SubscribedChannel` row locally. There is no Piped account sync.

## Player

Playback has two user-selectable styles:

- Fullscreen - the default native `AVPlayerViewController` flow.
- Embedded - an inline video at the top of a scrolling info page.

Both player styles support:

- Streaming through the selected Piped instance.
- Offline playback for completed downloads.
- Resume from saved watch position.
- Progress tracking into History.
- AVKit system controls, Picture in Picture, AirPlay, and background audio.
- Queue advancement.
- Captions kept off by default.
- Preferred audio-track selection.
- Runtime fallback when a selected stream fails.
- Optional Stats for Nerds diagnostics.

The fullscreen player adds an Info button to the transport controls. The Info sheet shows title, creator row, subscribe, playlist actions, feedback where applicable, description, comments, chapters, and queue.

The embedded player shows the same info content below the inline player. Comments are expanded in place rather than pushed to a separate comments page.

## Info Sheet

The shared info content is implemented by `PlayerInfoContent`.

It includes:

- Title and creator row.
- Creator avatar cluster and collaborator picker for multi-creator videos.
- Subscribe toggle.
- Suggest More / Suggest Less when personalized For You is active.
- Playlist creation and add-to-playlist actions.
- Collapsible plain-text description.
- Tappable timestamps in descriptions and comments.
- Comments preview or full inline comments.
- Chapters.
- Upcoming queue.

Collaborator enrichment can optionally fetch from youtube.com directly. It is off by default and controlled by Settings -> Privacy -> Resolve Collaborators via YouTube.

## Queue

The playback queue is session-only and lives in `AppModel.queuedVideos`. It is intentionally not persisted.

Rows expose:

- Play Next.
- Add to Queue.

When a video ends naturally, the player dequeues the next item. Queue items can also be started from the Info sheet.

## Playlists

Playlists are local SwiftData data. They do not sync to Piped or YouTube.

Users can:

- Create playlists from Library -> Playlists.
- Create a playlist from a video action menu or Info sheet.
- Add videos from long-press menus, Info sheet actions, and Shortcuts.
- Open a playlist and play saved videos.
- Delete playlists or remove playlist videos.

Playlist rows store denormalized video metadata so they can render without a fresh network request.

## Downloads

Downloads are implemented by `DownloadManager`, `DownloadStore`, `DownloadedVideo`, and `DownloadsView`.

Users can download videos from long-press menus or the Download Video shortcut. In-flight downloads are held in memory and completed downloads are persisted in SwiftData.

The download worker:

- Resolves stream details.
- Prefers a high-quality video-only plus audio pair when available.
- Downloads media in ranged chunks.
- Merges video and audio locally into an `.mp4`.
- Falls back to a progressive single-file stream when needed.
- Saves a local poster when possible.
- Saves a preferred caption file when available.
- Excludes media from device backups.
- Indexes completed downloads into Spotlight.

Downloaded videos play directly from disk and skip stream resolution. Offline playback has basic metadata and resume support, but no remote description or comments.

## Library

Library is implemented by `ProfileView` and sub-screens under `Atlas/Features/Profile/`.

Library includes:

- Channels.
- History.
- Playlists.
- Downloads.
- Settings.

History shows videos that have been opened and tracked by playback. Resume position updates after the user has watched at least five seconds. Clearing or deleting history removes rows from the local store.

## Settings

Settings include:

- Home feed mode.
- Hide Shorts.
- Shorts layout.
- Resolve collaborators via YouTube.
- Player style.
- Stats for Nerds.
- Piped instance.
- SponsorBlock.
- Backup & Data.
- Privacy policy link.
- App version.

Instance setup accepts HTTPS URLs for hosted instances and allows HTTP only for local/private-network hosts.

## SponsorBlock

SponsorBlock is on by default and uses the selected Piped instance's `/sponsors/{videoID}` proxy. Atlas never auto-skips. It shows a Skip button during enabled skip segments, and the user taps the button to jump to the segment end.

Enabled categories default to:

- Sponsor.
- Self-promotion.
- Interaction reminder.

The settings screen exposes all known SponsorBlock categories.

## App Shortcuts

Atlas exposes shortcuts for:

- Search.
- Resume Watching.
- Open For You.
- Open Downloads.
- Play Video.
- Download Video.
- Add to Playlist.
- Find Videos.

The video and playlist parameters are App Entities, so Shortcuts can chain results, resolve visible videos, use downloads, and create a playlist on demand when the spoken name does not exist yet.
