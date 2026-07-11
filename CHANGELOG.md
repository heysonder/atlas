# Changelog

All notable changes to Atlas are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
Tagged releases will use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Atlas has not published a tagged release yet.

## Unreleased

### Added
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
- Instance changes now cancel or reject stale feed, image, playback, cache, and
  media work instead of applying results from a previous Piped endpoint.
- Pagination and refresh failures preserve loaded content and expose explicit
  retry paths without cursor loops, silent truncation, or duplicate row IDs.
- Playlist/Favorites creation, App Intent writes, download restart/cleanup, and
  player Info state now preserve atomicity and validated-store behavior.

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
