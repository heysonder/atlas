# Changelog

All notable changes to Atlas are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
Tagged releases will use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Atlas has not published a tagged release yet.

## Unreleased

### Added
- **Chat button in the player.** A Liquid Glass "Chat" button sits beside
  Info (only when the video is live, or a chat replay was found by a
  one-page probe). Portrait opens a glass sheet with just the chat — first
  detent sits under the letterboxed video so it stays watchable, drag up for
  more; landscape docks a 360pt glass panel on the trailing edge over the
  still-playing video (tap the video to close). Live chat polls only while
  the page is open; replay follows the playhead. The Info sheet is back to
  the plain title/channel/description/comments layout — chat lives only on
  the Chat page. `PlayerChatSheet.swift`.
- **Age assurance for social features.**
  Comments, live chat, and chat replay are user-generated content, so Atlas
  can call the Declared Age
  Range API (`requestAgeRange(ageGates: 13)`) before showing or fetching any
  of them. Users under 13 — or anyone who declines to share, or on a device
  without an age range — see a notice in the player info sheet instead of
  UGC, with a "Check Age" button; Settings → Social Features shows the
  current state and re-checks on demand. Only the verdict (on/off) and its
  date are stored, and it's re-asked after 30 days. Adds the
  `com.apple.developer.declared-age-range` entitlement
  (`Atlas/Resources/Atlas.entitlements`). `SocialFeaturesGate` in
  `Atlas/Support/`, with tests. Off for now (`SocialFeaturesGate.isEnforced`);
  the raw outcome is logged under the `agegate` category when it runs.
- **On-device performance diagnostics (iOS 27).** Atlas now subscribes to
  MetricKit's Swift `MetricManager`: daily aggregated `MetricReport`s and
  per-event crash/hang `DiagnosticReport`s are archived as JSON under
  Application Support (30 days / 120 files) and never leave the device unless
  shared from the new Settings → Diagnostics page. Three StateReporting
  domains — `sh.cmf.atlas.playback` (stream path, e.g. `direct-av1-hls`),
  `sh.cmf.atlas.feed` (feed mode), `sh.cmf.atlas.livechat` — tag the reports
  so hang/hitch time comes back split by those states, and the same states
  appear in Instruments and Xcode Organizer. States are cleared while the
  app is inactive and restored on return, so suspended time isn't counted
  against a state. StateReporting is weak-linked so
  iOS 26 still launches; the page explains reports need iOS 27 there.
  `AppDiagnostics` + `DiagnosticsReportStore` in `Atlas/Support/Diagnostics/`,
  with store tests.
- **Live chat on live streams.** When a video is live right now, the player
  info panel shows a Live Chat pane in place of comments: a bounded,
  auto-following transcript that polls the instance's `/livechat/:videoId`
  endpoint at the server-suggested interval (clamped to 5–60s to protect
  small self-hosted instances), de-duplicates the rolling message window by
  id, and keeps the newest 300 messages. Author rows show channel-owner,
  moderator, member, and verified badges. The endpoint is not part of
  upstream Piped, so instances without it fall back to the regular comments
  section; when a stream ends mid-watch the transcript stays up with a
  "Live chat ended" notice. New `LiveChatPage`/`LiveChatMessage` wire models
  and `PipedClient.liveChat(videoID:)` in PipedKit, plus `LiveChatLoader`
  and the chat UI in `Atlas/Features/Player/`.
- **Chat replay for ended live streams.** Archived streams get a Chat Replay
  pane above comments, paged from the start of the stream through
  `/livechat/:videoId?replay=true&pageToken=…`. Piped reports an ended
  broadcast as an ordinary video, so the panel probes the endpoint for every
  non-live video (one request, alongside comments) and only shows the pane
  when a transcript comes back. Messages appear in step with playback, in
  the same pinned-to-latest pane as live chat (scroll up to pause following,
  scroll back down or tap "Latest" to resume). The server can't seek, so the
  loader buffers one page per playback tick ~30s ahead of the playhead and a
  far-forward seek catches up gradually instead of bulk-walking hundreds of
  pages; the buffer keeps the newest 2,000 messages. New
  `PipedClient.liveChatReplay(videoID:pageToken:)` and `LiveChatReplayLoader`.
- **Public-repository foundations.** Added contributor and security-reporting
  guides, public design principles, a strict Swift formatting contract, editor
  defaults, GitHub Actions build/test validation, and an Apple privacy manifest
  for UserDefaults and disk-space access.
- **Safety regression coverage.** Added focused tests for backups, persistence
  limits, downloads, instance isolation, media policy, pagination, comments,
  image loading, stream identity, and playback fallback behavior.
- **Siri & App Intents.** Atlas now exposes its core actions to Siri, Spotlight,
  and the Shortcuts app. Say "Search Atlas", "Resume watching in Atlas" (which
  replies with a spoken line and a snippet card), "Open For You", or "Open Atlas
  downloads". Watched videos and offline downloads are published to Spotlight —
  downloads are findable and playable fully offline — and tapping a result jumps
  straight into the player, preferring the local file when present. New
  `Atlas/Features/Intents/` module:
  `VideoEntity`, the intents, `AtlasShortcuts`, and `SpotlightIndexer`.
- **For You learns from searches, saves, and subscriptions.** Beyond watch
  history and thumbs, the personalized feed now folds in your recent searches,
  playlist saves, and the channels you subscribe to: searches seed fresh,
  intent-matched videos and join your taste profile; saving a video counts as a
  strong "keep this"; and your subscriptions both seed their recent uploads into
  the pool and get an explicit ranking boost (matched by channel ID), so the
  channels you follow surface even on a quieter topic day. Searches are stored
  on-device (`SearchEntry`), de-duped, and aged out after 30 days.
- **For You weighs watches by how much you finished.** A watch now counts in
  proportion to how far through the video you got: ~half scores as before, while
  reaching the end (≥80% — near-finishes count, since end cards and ads mean
  people stop in the last 10–20%) counts up to 4× toward both its topic and its
  channel, so the things you watch all the way through pull the feed harder.
- **Comments on videos.** The player info sheet now shows a comment count, a
  two-comment preview, and a "View all comments" link that pushes a full,
  scrollable comments screen with pagination and expandable reply threads.
- PipedKit: `comments(videoID:)` and `commentsNextPage(videoID:nextpage:)`
  endpoints with `Comment` / `CommentsPage` models.

### Changed
- **No default instance, even as a shortcut.** The missing-instance screen
  used to offer a one-tap "Use the default" that pointed Atlas at a public
  third-party instance. That button is gone; the screen now opens Instance
  settings and links to Piped for Atlas (self-hosting), the Piped
  self-hosting docs, and Privacy Guides' frontends page so people pick an
  instance knowingly. `AppModel.defaultInstanceURL` was removed.
- **Live chat polls every 4s** (2s floor) instead of honoring the server's
  10s hint; the chat pane is taller (420pt) and sits on a solid background so
  text doesn't shimmer over the sheet's glass; `:shortcode:` emoji
  (`:speaker_high_volume:`, `:face_with_rolling_eyes:`, …) render as emoji via
  a bundled 4,946-entry CLDR/alias table (`EmojiShortcodes`).
- **For You no longer flashes while it loads.** The feed rendered three
  times per load (first source → all sources → refined), replacing the whole
  list each time. It now waits for every source before the first paint (or
  renders the partial pool after the 8s initial-response timeout instead of
  falling to trending), and later re-ranks animate rows into place instead of
  rebuilding the list.
- **Search history keeps the 15 most recent searches**; older ones are
  evicted on record and pruned when the Search tab appears.
- **Player style and Stats for Nerds are hidden** behind
  `SettingsView.showsPlayerOptions` (developer knobs).
- **Network and download boundaries are policy-enforced.** API, media, image,
  caption, artwork, redirect, and download requests now share the selected
  instance's destination policy, bounded response handling, and checked range
  parsing. Download paths and cleanup are contained to recognized artifacts.
- **Persistence and backups are bounded and transactional.** Remote metadata is
  normalized before storage, backup imports validate before mutation, and
  rejected writes no longer leave UI or partial records out of sync.
- **Large implementation files are domain-focused.** Player, recommendation,
  download, backup, PipedKit model, and test catch-alls were split while keeping
  existing state and lifecycle ownership.
- **Accessibility and large text were strengthened.** Media rows now expose
  useful VoiceOver state, queue reordering has accessible actions, controls meet
  normal target sizes, and library/player layouts adapt at accessibility sizes.
- **"Watched" now means ≥80% seen.** The Watched badge, the Home feed's
  hide-watched filter, and the For You candidate exclusion all now treat a video
  as watched only once you've seen ≥80% of it (near-finishes count — end cards and
  ads make people stop early). Open a video and bail early and it stays unbadged
  and keeps appearing in your feed until you actually get through it.
- **Redesigned the player info sheet.** The uploader line is now a channel row
  with the channel avatar, name (with a verified badge), and subscriber count,
  paired with a circular Liquid Glass `+` / `✓` subscribe toggle that matches
  the channel page. The description collapses to three lines with a
  *Show more / less* toggle so the comments below stay reachable; the sheet
  opens at the medium detent and reveals comments as you drag it up.

### Fixed
- **Ended broadcasts no longer show a LIVE badge.** Piped keeps
  `livestream: true` on past streams in search and channel rows; `isLive`
  now also requires the live duration sentinel.
- **Background audio from the full-screen player.** Locking the phone while
  the full-screen player was up stopped playback (only PiP kept going). The
  player now sets `audiovisualBackgroundPlaybackPolicy = .continuesIfPossible`
  so audio continues with the screen off while AVKit stays attached and keeps
  publishing lock-screen Now Playing metadata (an earlier detach-on-background
  approach blanked the lock screen).
- Channel-tab load failures and live-stream resolution are now logged under
  the `channel` category instead of being swallowed.
- **Missing channel avatars in For You / search rows.** Piped's related-
  streams and search rows often omit `uploaderAvatar`, so rows showed the
  placeholder. `ChannelAvatarResolver` now remembers every avatar seen per
  channel id (persisted) and, for channels never seen, fetches `/channel/:id`
  with a 2-request cap and a 10-minute negative cache.
- **On-device playback broken since the public-release hardening.** Since
  `879a1e8`, direct and HLS items were loaded through the custom-scheme
  `PolicyMediaResourceLoader` proxy; on device that left AV1 HLS at
  "waiting" (crossed-out play button), or playing audio with a black
  picture. Bisected against the July TestFlight build (`c081b15` plays,
  `879a1e8` doesn't). Direct/HLS items now use AVFoundation's native loader
  via `PolicyMediaAssetFactory.nativeAsset`, with the root URL still
  validated against the destination policy; composed (video+audio) items
  keep the proxy.
- **Playback dead after a media-services reset.** When mediaserverd
  restarts (AVFoundation -11819) the old `AVPlayer` never plays again, so
  the runtime fallback rebuilt the item on a dead player (`item=missing`).
  The fallback now swaps in a fresh `AVPlayer` on the presented controller,
  moving progress, sponsor, and info-time observers over, before loading
  the fallback item.
- **Two-column feed on landscape iPhone.** The feed chose stack-vs-grid by
  size class, so a 667pt-wide landscape phone (compact) stayed single-column.
  `GroupedVideoList` now measures its width and uses the grid whenever two
  300pt columns fit.
- **Channel avatars retry when they fail to load.** A feed avatar that
  fails now retries twice while its row is on screen (1.5s, then 4s), and
  every avatar URL carries a global budget of four failures before it goes
  cold for ten minutes — so a broken image never turns scrolling into a
  request storm against the Piped instance. `AvatarRetryPolicy` in
  `Atlas/Support/`, with tests.
- **Player info sheet is Liquid Glass again.** The hosted sheet content
  painted an opaque background over `UISheetPresentationController`'s glass,
  so the sheet looked flat instead of translucent like Maps. The content is
  now transparent, so the medium detent shows the video through the glass
  and the sheet goes opaque only at full height.
- Instance changes now cancel or reject stale feed, image, playback, cache, and
  media work instead of applying results from a previous Piped endpoint.
- Pagination and refresh failures preserve loaded content and expose explicit
  retry paths without cursor loops, silent truncation, or duplicate row IDs.
- Playlist/Favorites creation, App Intent writes, download restart/cleanup, and
  player Info state now preserve atomicity and validated-store behavior.
- Policy-loaded HLS playback now redirects media segments through AVFoundation's
  supported HTTP path instead of misclassifying segment URLs as manifests.

## Initial MVP baseline - 2026-06-13

Initial MVP — a native, privacy-respecting YouTube client for iOS built on
[Piped](https://github.com/TeamPiped/Piped) (SwiftUI + Liquid Glass, iOS 26).

### Added
- **Feed.** Local subscriptions with an aggregated unauthenticated feed, plus a
  personalized "For You" mode and an option to hide Shorts.
- **Channels.** Channel pages with subscribe / unsubscribe.
- **Search.** Videos and channels, with query suggestions.
- **Player.** Native `AVPlayer` playback (HLS with progressive fallback),
  Picture-in-Picture, AirPlay, background audio, SponsorBlock skipping, and
  resume-from-last-position.
- **Downloads.** Offline video downloads.
- **Profile.** Watch history, and settings with a Piped instance picker.
- **PipedKit.** A standalone Swift package wrapping the Piped API: Codable
  models, an async `PipedClient`, the public instance directory, and
  stream-selection logic.
