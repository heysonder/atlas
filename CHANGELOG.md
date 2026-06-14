# Changelog

All notable changes to Atlas are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Comments on videos.** The player info sheet now shows a comment count, a
  two-comment preview, and a "View all comments" link that pushes a full,
  scrollable comments screen with pagination and expandable reply threads.
- PipedKit: `comments(videoID:)` and `commentsNextPage(videoID:nextpage:)`
  endpoints with `Comment` / `CommentsPage` models.

### Changed
- **Redesigned the player info sheet.** The uploader line is now a channel row
  with the channel avatar, name (with a verified badge), and subscriber count,
  paired with a circular Liquid Glass `+` / `✓` subscribe toggle that matches
  the channel page. The description collapses to three lines with a
  *Show more / less* toggle so the comments below stay reachable; the sheet
  opens at the medium detent and reveals comments as you drag it up.

## [1.0.0] - 2026-06-13

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

[Unreleased]: https://github.com/heysonder/atlas/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heysonder/atlas/releases/tag/v1.0.0
