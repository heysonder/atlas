# Playback

Playback is centered on `PlayRequest`, `AppModel.nowPlaying`, `VideoPlayerPresenter`, `EmbeddedPlayerView`, and `StreamPlaybackBuilder`.

## Playback request

`PlayRequest` carries the minimum metadata needed to start playback:

- `videoID`.
- `title`.
- `uploader`.
- `thumbnail`.
- Optional local media URL for downloads.
- Optional local caption URL and metadata.

Any screen can start playback by setting `app.nowPlaying`.

## Player styles

Atlas has two player styles.

### Fullscreen

`VideoPlayerPresenter` is a `UIViewControllerRepresentable` that presents a native `AVPlayerViewController` directly.

The fullscreen player:

- Uses the native AVKit controller.
- Allows Picture in Picture.
- Allows AirPlay.
- Lets AVKit own Now Playing state.
- Keeps the player attached for background audio.
- Adds an Info button to the native transport controls (falls back to a floating overlay pill if the private controls hierarchy can't be matched).
- Adds an optional Stats for Nerds overlay.
- Adds a SponsorBlock skip overlay when enabled segments are active.

### Embedded

`EmbeddedPlayerView` shows an inline `AVPlayerViewController` above the shared player info content.

The embedded player:

- Uses a dedicated `EmbeddedPlayerModel`.
- Shows title, channel, description, comments, chapters, and queue under the video.
- Expands comments in place.
- Includes a custom close control beside native player controls.
- Defers teardown while Picture in Picture is active.

## Online stream flow

For streamed playback:

1. The player asks `AppModel` to resolve stream details for the `videoID`.
2. `AppModel.resolveStream` returns cached details, joins an in-flight task, or calls `PipedClient.streams(videoID:)`.
3. The player asks `StreamPlaybackBuilder.makePlayerItem` to prepare an `AVPlayerItem`.
4. The player installs diagnostics, captions behavior, end observer, runtime fallback, metadata, and overlays.
5. The player seeks to saved resume position when available.
6. The player starts playback and records history.

`AppModel` caches stream details for one hour and caps the cache at 48 videos. Row-driven prefetching is throttled so scroll bursts do not spawn unbounded `/streams` calls.

## Offline playback flow

For a completed download, `PlayRequest.localURL` is set. The player skips stream resolution and builds an `AVPlayerItem` directly from the local file.

Offline playback still supports:

- Resume.
- History.
- Basic Now Playing metadata.
- Captions when a local caption sidecar exists.
- Queue advancement.

Offline playback does not fetch remote stream details, comments, description, or related metadata.

## Stream source selection

`StreamPlaybackBuilder` prefers adaptive playback first.

Selection order:

1. AV1 HLS when the device supports AV1 and the Piped instance extracted AV1 video streams.
2. Piped/YouTube HLS manifest when available.
3. A composed video-only plus audio pair when it is strictly sharper than the available manifest ladder.
4. Progressive audio+video fallback.

The goal is to let AVPlayer own adaptive quality selection unless a fixed composed pair clearly gives a better maximum quality.

## AV1 HLS

AV1 HLS uses the Piped instance endpoint:

```text
/hls/av1/{videoID}/master.m3u8
```

Atlas only attempts it when:

- The device has AV1 hardware decode support.
- The resolved `VideoDetail` contains at least one AV1 video stream.

The AV1 HLS manifest is loaded with no-cache headers, and the cached URL response for that manifest is evicted before use. This prevents stale signed media URLs from being reused.

AV1 HLS gets a longer startup fallback window than ordinary playback: 45 seconds instead of 15 seconds. Some instances cold-generate the AV1 master slowly.

## Runtime fallback

Playback can fail after an item is created. Atlas handles this by observing:

- `AVPlayerItem.status`.
- Playback stalls.
- Failure-to-play-to-end notifications.
- Access/error logs.
- A delayed "still stalled" check after startup.

Fallback behavior depends on the initial source:

- HLS can fall back to composed or direct playback.
- Composed startup can fall back to direct playback.
- Progressive/direct fallback usually has no further fallback.

If stream details are older than 30 minutes, fallback refreshes stream details before rebuilding the player item so expired signed URLs are not reused.

## Audio and captions

Atlas disables AVPlayer's automatic media selection criteria and explicitly selects the preferred audio track for non-AV1 direct/composed items.

Audio scoring favors:

- Preferred locale.
- English fallback.
- Original tracks.
- Higher bitrate.

Dub tracks are down-ranked.

Captions are kept off by default. Downloads may save one preferred subtitle sidecar file, which can be used during offline playback.

## Resume and history

Playback history is recorded by `PlaybackHistoryStore`.

Rules:

- A video is recorded when playback starts.
- Position saves after at least five seconds.
- The latest position updates the `watchedAt` timestamp.
- Resume is skipped when the saved position is within 10 seconds of the known end.
- A video counts as watched for feed filtering and badges at 80 percent completion.

## Queue

The queue is in-memory only and belongs to `AppModel`.

Actions:

- Play Next inserts at the front.
- Add to Queue appends.
- Natural playback end dequeues the next request.
- Info sheet queue rows can start a queued video immediately.
- Closing the app clears the queue.

## Info sheet and comments

The fullscreen player places an Info button in the native transport-control row (shared `TransportBarButtonInstaller`; the floating overlay pill remains as an automatic fallback). The button presents `PlayerInfoSheet`, which wraps `PlayerInfoContent`.

Player info includes:

- Channel row and subscribe action.
- Creator/collaborator picker.
- Suggest More / Suggest Less for personalized mode.
- Playlist actions.
- Description with tappable timestamps.
- Comments preview.
- Full comments page.
- Chapters.
- Queue.

Comments are loaded through `CommentsLoader`. HTML is stripped once per loaded comment. Timestamps are extracted once and tapped timestamps seek the player.

## SponsorBlock

When SponsorBlock is enabled, the player fetches segments after playback starts so video startup is not blocked.

Only segments with `actionType == "skip"` and positive duration are usable. Atlas shows a "Skip ..." button while the playhead is inside a segment. Tapping seeks to the segment end. It does not skip automatically.

## Diagnostics

Stats for Nerds shows an overlay with playback diagnostics. Player logs use `NSLog` with `Atlas.player` and include source names such as:

- `direct-av1-hls`.
- `direct-hls`.
- `direct-initial`.
- `composed-initial`.
- `fallback-hls`.
- `fallback-direct`.
- `fallback-composed`.
- `local`.

Use these names when diagnosing source selection or fallback behavior.
