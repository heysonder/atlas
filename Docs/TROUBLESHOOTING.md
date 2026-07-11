# Troubleshooting

Use this guide for common Atlas failures. Prefer checking the exact configured Piped instance and current logs before assuming the app behavior is generic.

## Online screens say an instance is missing

Atlas does not ship with a default Piped instance.

Fix:

1. Open Library.
2. Open Settings.
3. Open Instance.
4. Enter a valid Piped API URL.

Hosted instances must use HTTPS. HTTP is accepted only for local/private hosts.

## A Piped instance URL will not save

Validation accepts:

- HTTPS with a host.
- HTTP for `localhost`, loopback, private IPv4, private IPv6, link-local hosts, or single-label local hosts.

Validation rejects:

- Empty strings.
- Unsupported schemes.
- Public HTTP hosts.
- URLs without a host.

## Search, Home, or Channels fail

Likely causes:

- No instance is configured.
- The instance is down.
- The instance is blocked by YouTube.
- The endpoint returned partial or empty data.
- The network request timed out.

Checks:

- Try a known-good custom instance.
- Try Search for a simple query.
- Open a channel directly from a known search result.
- Check whether only one endpoint is failing, such as `/feed/unauthenticated`.

Home can fall back to trending when subscriptions are empty or degraded, but Search and Channel detail still depend on instance endpoints.

## A video says no playable stream

Likely causes:

- The instance failed stream extraction.
- YouTube blocked the instance.
- The video is restricted, unavailable, or live but not started.
- Piped returned no HLS, no compatible progressive stream, and no compose-able video/audio pair.

Try:

- Refreshing the video.
- Switching instances.
- Checking whether `/streams/{videoID}` returns playable HLS or mp4 streams.

## AV1 HLS starts slowly or falls back

AV1 HLS can be slow on cold instances because the master playlist may be generated on demand.

Atlas gives AV1 HLS 45 seconds before fallback. Non-AV1 paths use a shorter 15 second fallback window.

Useful log source names:

- `direct-av1-hls`.
- `fallback-composed`.
- `fallback-direct`.

## Playback stalls after starting

Possible causes:

- Expired signed media URLs.
- CDN throttling.
- HLS manifest failure.
- Composed audio/video asset loading failure.
- Network interruption.

Atlas observes stalls and item failures. If stream details are stale, it refreshes `/streams` before fallback.

Enable Stats for Nerds for runtime source, buffer, bitrate, resolution, and stall details.

## Captions do not appear

Captions are kept off by default. Downloads save only one preferred caption sidecar when the source exposes a usable subtitle URL.

If no subtitle is exposed by Piped, Atlas has no caption file to save.

## SponsorBlock does not show a skip button

Check:

- SponsorBlock is enabled.
- At least one category is enabled.
- The current video has SponsorBlock data for those categories.
- The segment action type is `skip`.
- The playhead is currently inside a segment.

SponsorBlock is fetched after playback starts and does not block video startup.

## Downloads fail

Possible causes:

- No playable download stream.
- Storage directory could not be created.
- Media CDN rejected a range request.
- Network timed out.
- Merge failed because audio or video tracks were missing.

Atlas downloads in chunks and retries transient chunk failures. A failed in-flight row can be dismissed, and a fresh download can be attempted.

## Downloads disappear after a crash

At launch, Atlas removes orphaned final and temporary media files that are not claimed by completed `DownloadedVideo` rows. This protects the downloads directory from crash leftovers.

If a download was in progress during a crash, it may be removed and should be re-downloaded.

## The local library warning appears

If Atlas cannot open the persistent SwiftData store, it launches with temporary storage and leaves existing on-disk data untouched.

Do not export from that temporary session as a recovery backup: it starts with
an empty in-memory store and does not contain the inaccessible library. Preserve
the app container, then recover from a backup created while the persistent store
was healthy or diagnose the original store. Do not assume the data was deleted.

## Spotlight result plays the wrong path

Atlas prefers a downloaded copy when present. If a video exists in both downloads and history, the Spotlight download entry should win so playback can work offline.

If a stale Spotlight item remains, relaunching Atlas deletes its current and
known legacy domains before rebuilding them from the local stores.

## Shortcut cannot resolve a video

Resolution sources:

- Current visible video registry.
- Completed downloads.
- Piped search.

If none of those can resolve the video, check that:

- The video is visible in Atlas or downloaded.
- A Piped instance is configured for search-backed resolution.
- The shortcut phrase provided enough detail for Siri to match a video.

## App build fails after files moved

Atlas uses XcodeGen. Regenerate the project:

```sh
xcodegen generate
```

Then rerun the build or tests.

## App tests fail on a missing simulator

The documented test destination uses:

```text
platform=iOS Simulator,name=iPhone 17
```

If that simulator is unavailable, use an installed iOS simulator and keep the scheme as `Atlas`.
