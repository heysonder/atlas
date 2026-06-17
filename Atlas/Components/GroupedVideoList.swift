import SwiftUI
import SwiftData
import PipedKit

/// One row in a feed: a full-width video, a run of Shorts (1–2 per row), or a
/// single horizontal Shorts shelf (carousel layout).
private enum FeedRow: Identifiable {
    case video(StreamItem)
    case shorts([StreamItem])
    case shelf([StreamItem])

    var id: String {
        switch self {
        case .video(let v): "v:" + v.id
        case .shorts(let s): "s:" + s.map(\.id).joined(separator: "+")
        case .shelf(let s): "shelf:" + s.map(\.id).joined(separator: "+")
        }
    }
}

/// Inline layout: groups a flat item list so that Shorts always pair up
/// two-per-row, while regular videos stay full width.
///
/// A lone Short is held back to pair with the *next* Short rather than taking a
/// full-width row with half of it empty — so interspersed Shorts (one here, a few
/// there) still pack two-per-row instead of wasting space. Video order is
/// preserved; a held-back Short surfaces at the next Short's position. Only a
/// final leftover Short (when the total count is odd) ever sits alone.
private func inlineFeedRows(_ items: [StreamItem]) -> [FeedRow] {
    var rows: [FeedRow] = []
    var pending: StreamItem?   // a single Short waiting for a partner
    for item in items {
        if item.isShort == true {
            if let first = pending {
                rows.append(.shorts([first, item]))
                pending = nil
            } else {
                pending = item
            }
        } else {
            rows.append(.video(item))
        }
    }
    if let last = pending { rows.append(.shorts([last])) }
    return rows
}

/// Carousel layout: pulls every Short into one horizontal shelf placed just below
/// the first few videos, so the feed leads with full videos and Shorts never
/// break the vertical rhythm. Video order is otherwise preserved.
private func carouselFeedRows(_ items: [StreamItem]) -> [FeedRow] {
    let shorts = items.filter { $0.isShort == true }
    let videos = items.filter { $0.isShort != true }
    guard !shorts.isEmpty else { return videos.map(FeedRow.video) }

    var rows: [FeedRow] = []
    let insertAfter = min(3, videos.count)   // lead with up to 3 videos, then the shelf
    for (i, video) in videos.enumerated() {
        rows.append(.video(video))
        if i + 1 == insertAfter { rows.append(.shelf(shorts)) }
    }
    if videos.isEmpty { rows.append(.shelf(shorts)) }
    return rows
}

private func groupedFeedRows(_ items: [StreamItem], layout: ShortsLayout) -> [FeedRow] {
    switch layout {
    case .inline: inlineFeedRows(items)
    case .carousel: carouselFeedRows(items)
    }
}

/// A `LazyVStack` of videos that renders Shorts as paired 9:16 posters (or one
/// horizontal shelf, in carousel layout) and warms upcoming thumbnails as rows
/// appear. Shared by the feed, search, recs, channel.
struct GroupedVideoList: View {
    let items: [StreamItem]
    var avatarFallback: String? = nil
    var channelIDFallback: String? = nil
    var spacing: CGFloat = 20
    /// How Shorts are arranged. Only the feed opts into `.carousel`; everything
    /// else keeps the inline paired layout.
    var shortsLayout: ShortsLayout = .inline
    /// Video ids the user has already watched. Surfaces that show the full catalog
    /// (e.g. a channel page) pass this so watched items get a "Watched" badge; the
    /// Home feed hides watched videos instead, so it leaves this empty.
    var watchedIDs: Set<String> = []
    /// Called as each item scrolls on (e.g. to warm the stream extraction).
    var onAppearItem: ((StreamItem) -> Void)? = nil
    let onPlay: (StreamItem) -> Void

    /// iPhone (compact) stays a single column; iPad and larger (regular) break the
    /// feed into a 2–4 column grid sized to the available width.
    @Environment(\.horizontalSizeClass) private var hSize
    @Query(sort: \Playlist.createdAt, order: .reverse) private var menuPlaylists: [Playlist]
    @Query private var menuFeedback: [Feedback]
    @Query(sort: \DownloadedVideo.createdAt, order: .reverse) private var menuDownloads: [DownloadedVideo]
    /// Measured width of the list, used to pick the grid's column count.
    @State private var gridWidth: CGFloat = 0

    private var menuFeedbackByVideoID: [String: Int] {
        Dictionary(uniqueKeysWithValues: menuFeedback.map { ($0.videoID, $0.signal) })
    }

    private var menuDownloadsByVideoID: [String: DownloadedVideo] {
        Dictionary(uniqueKeysWithValues: menuDownloads.map { ($0.videoID, $0) })
    }

    var body: some View {
        if hSize == .regular {
            gridLayout
        } else {
            stackLayout
        }
    }

    /// Single-column feed (iPhone): full-width videos with Shorts paired 2-up or
    /// pulled into a shelf, per `shortsLayout`.
    private var stackLayout: some View {
        LazyVStack(spacing: spacing) {
            ForEach(groupedFeedRows(items, layout: shortsLayout)) { row in
                switch row {
                case .video(let item):
                    videoCell(item)
                case .shorts(let pair):
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(pair) { short in
                            ShortPoster(item: short, watched: isWatched(short)) { onPlay(short) }
                                .videoContextMenu(
                                    short,
                                    playlists: menuPlaylists,
                                    feedbackByVideoID: menuFeedbackByVideoID,
                                    downloadsByVideoID: menuDownloadsByVideoID)
                        }
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .onAppear { pair.forEach(appeared) }
                case .shelf(let shorts):
                    ShortsShelf(items: shorts, watchedIDs: watchedIDs,
                                playlists: menuPlaylists,
                                feedbackByVideoID: menuFeedbackByVideoID,
                                downloadsByVideoID: menuDownloadsByVideoID,
                                onAppearItem: onAppearItem, onPlay: onPlay)
                }
            }
        }
    }

    /// Multi-column feed (iPad and larger): regular videos flow into an adaptive
    /// grid; Shorts collapse into a single horizontal shelf placed after the first
    /// row (their tall 9:16 posters don't tile cleanly beside wide 16:9 cards).
    private var gridLayout: some View {
        let columns = columnCount(for: gridWidth)
        let track = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
                          count: columns)
        let shorts = items.filter { $0.isShort == true }
        let videos = items.filter { $0.isShort != true }
        // Lead with one full row of videos, then the shelf, then the rest — so the
        // feed opens on real videos rather than a wall of Shorts.
        let leadCount = shorts.isEmpty ? videos.count : min(columns, videos.count)
        let lead = videos.prefix(leadCount)
        let rest = videos.dropFirst(leadCount)

        return LazyVStack(spacing: spacing) {
            if !lead.isEmpty {
                LazyVGrid(columns: track, spacing: spacing) {
                    ForEach(lead) { videoCell($0, reservesTitleSpace: true) }
                }
            }
            if !shorts.isEmpty {
                ShortsShelf(items: shorts, watchedIDs: watchedIDs,
                            playlists: menuPlaylists,
                            feedbackByVideoID: menuFeedbackByVideoID,
                            downloadsByVideoID: menuDownloadsByVideoID,
                            onAppearItem: onAppearItem, onPlay: onPlay)
            }
            if !rest.isEmpty {
                LazyVGrid(columns: track, spacing: spacing) {
                    ForEach(rest) { videoCell($0, reservesTitleSpace: true) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { gridWidth = $0 }
    }

    /// One video card, shared by the stack and grid layouts. The grid reserves a
    /// two-line title height so every card matches, keeping the columns aligned.
    private func videoCell(_ item: StreamItem, reservesTitleSpace: Bool = false) -> some View {
        VideoRow(item: item,
                 avatarFallback: avatarFallback,
                 channelIDFallback: channelIDFallback,
                 watched: isWatched(item),
                 reservesTitleSpace: reservesTitleSpace) { onPlay(item) }
            .videoContextMenu(
                item,
                playlists: menuPlaylists,
                feedbackByVideoID: menuFeedbackByVideoID,
                downloadsByVideoID: menuDownloadsByVideoID)
            .onAppear { appeared(item) }
    }

    /// Columns scale with width: ~one card per 300pt, capped at 4. Defaults to 2
    /// before the first width measurement (we're already at regular width here).
    private func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 2 }
        return min(4, max(1, Int(width / 300)))
    }

    private func isWatched(_ item: StreamItem) -> Bool {
        guard let id = item.videoID else { return false }
        return watchedIDs.contains(id)
    }

    /// Notify + warm the thumbnails of the next handful of items so they're ready
    /// before the user scrolls to them.
    private func appeared(_ item: StreamItem) {
        onAppearItem?(item)
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let start = idx + 1, end = min(start + 10, items.count)
        guard start < end else { return }
        let urls = items[start..<end].map { Thumbnail.upgraded($0.thumbnail) }
        Task { await ThumbnailPrefetcher.shared.prefetch(urls) }
    }
}

/// A horizontal, swipeable row of Shorts posters with a "Shorts" header. Lazily
/// loads posters so a long shelf doesn't fetch every thumbnail up front.
private struct ShortsShelf: View {
    let items: [StreamItem]
    var watchedIDs: Set<String> = []
    var playlists: [Playlist] = []
    var feedbackByVideoID: [String: Int] = [:]
    var downloadsByVideoID: [String: DownloadedVideo] = [:]
    var onAppearItem: ((StreamItem) -> Void)? = nil
    let onPlay: (StreamItem) -> Void

    private let cardWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shorts", systemImage: "play.square.stack.fill")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { short in
                        ShortPoster(item: short,
                                    watched: short.videoID.map(watchedIDs.contains) ?? false) { onPlay(short) }
                            .videoContextMenu(
                                short,
                                playlists: playlists,
                                feedbackByVideoID: feedbackByVideoID,
                                downloadsByVideoID: downloadsByVideoID)
                            .frame(width: cardWidth)
                            .onAppear { onAppearItem?(short) }
                    }
                }
            }
            .scrollClipDisabled()
        }
        .onAppear {
            let urls = items.prefix(8).map { Thumbnail.upgraded($0.thumbnail) }
            Task { await ThumbnailPrefetcher.shared.prefetch(urls) }
        }
    }
}
