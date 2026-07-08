# PipedKit

`PipedKit` is the local Swift package that isolates Piped API calls, response models, decoding tolerance, and low-level helpers from the app UI.

## Package contents

```text
PipedKit/
  Package.swift
  Sources/PipedKit/
    PipedClient.swift
    Models.swift
    HTMLText.swift
```

## Client

`PipedClient` is a thin async client for one Piped instance.

It is initialized with an `api_url`, for example:

```text
https://api.example.com
```

The client uses an ephemeral bounded `URLSession`:

- Request timeout: 15 seconds.
- Resource timeout: 45 seconds.

These limits are intentionally generous because `/streams` extraction can take several seconds on self-hosted instances.

## Endpoints

Atlas currently uses these Piped endpoints:

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `searchPage` | `/search` | First page of search results. |
| `searchNextPage` | `/nextpage/search` | Search pagination. |
| `suggestions` | `/suggestions` | Search autocomplete. |
| `streams` | `/streams/{videoID}` | Video details, streams, comments metadata, related videos. |
| `av1HLSMasterURL` | `/hls/av1/{videoID}/master.m3u8` | AV1 HLS master URL builder. |
| `channel` | `/channel/{channelID}` | Channel metadata and uploads. |
| `channelNextPage` | `/nextpage/channel/{channelID}` | Channel upload pagination. |
| `channelTab` | `/channels/tabs` | Channel tab content, such as Shorts. |
| `comments` | `/comments/{videoID}` | First comment page. |
| `commentsNextPage` | `/nextpage/comments/{videoID}` | Comment and reply pagination. |
| `sponsorSegments` | `/sponsors/{videoID}` | SponsorBlock segment data. |
| `feed` | `/feed/unauthenticated` | Aggregated channel feed. |
| `trending` | `/trending` | Regional trending fallback. |

`fetchInstances` still exists for the public instance directory, but the current app UI expects a custom instance URL instead of showing a public list.

## Error handling

`PipedError` maps:

- Invalid URLs.
- Non-2xx HTTP statuses.
- Piped upstream errors.
- No playable stream.
- Decode failures.

Some upstream errors are made user-friendly:

- `LIVE_STREAM_OFFLINE` becomes a live-event-not-started message.
- `SignInConfirmNotBotException` becomes an instance-blocked-by-YouTube message.

Other upstream messages are surfaced rather than collapsed into generic HTTP failures.

## Decoding strategy

Piped responses are often partial or degraded. Models use optional fields heavily and some arrays decode lossily. If one element in a stream, chapter, comment, or segment list is malformed, Atlas can still use the rest of the response.

Important response models:

- `StreamItem` - shared item shape for search, feed, channel uploads, and related videos.
- `VideoDetail` - `/streams` detail payload.
- `Stream` - video/audio stream metadata.
- `Subtitle`.
- `VideoChapter`.
- `SponsorSegment`.
- `Channel`.
- `Comment`.
- `SearchResponse`.
- `PipedInstance`.

## IDs

`PipedID` extracts:

- Video IDs from `/watch?v=...` URLs.
- Channel IDs from `/channel/...` URLs.

The app relies on these helpers rather than duplicating string parsing in feature code.

## Stream helpers

`VideoDetail` includes helper properties for playback and downloads:

- `playableURL`.
- `bestProgressiveDownload`.
- `hasAV1VideoStream`.
- `maxAV1VideoStreamHeight`.
- `maxNonAV1VideoStreamHeight`.
- `bestComposedSource`.
- `preferredSubtitle`.

`Stream` includes codec/container helpers:

- H.264 detection.
- AV1 detection.
- VP9/WebM exclusion.
- Playable audio detection.
- Audio language hints.

These helpers keep media compatibility decisions close to decoded Piped data.

## SponsorBlock

Sponsor categories are represented by `SponsorCategory`.

Each category has:

- API raw value.
- Settings label.
- Player skip-button label.

`PipedClient.sponsorSegments` encodes selected category IDs as the JSON-array string expected by Piped.

## Comments

Comment models strip HTML in app code through `HTMLText.plain`. `CommentTimestamp.extract` recognizes `m:ss` and `h:mm:ss` style timestamps and normalizes them to seconds for tappable seeking.

Comments support:

- Pinned state.
- Creator heart.
- Like counts.
- Verified authors.
- Reply counts.
- Reply pagination.

## HTML text

`HTMLText.plain` converts HTML-ish text from Piped descriptions and comments into displayable plain text. Use it at load time rather than inside frequently re-rendering SwiftUI bodies.
