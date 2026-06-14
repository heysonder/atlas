import SwiftUI
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
    /// Called as each item scrolls on (e.g. to warm the stream extraction).
    var onAppearItem: ((StreamItem) -> Void)? = nil
    let onPlay: (StreamItem) -> Void

    var body: some View {
        LazyVStack(spacing: spacing) {
            ForEach(groupedFeedRows(items, layout: shortsLayout)) { row in
                switch row {
                case .video(let item):
                    VideoRow(item: item,
                             avatarFallback: avatarFallback,
                             channelIDFallback: channelIDFallback) { onPlay(item) }
                        .videoContextMenu(item)
                        .onAppear { appeared(item) }
                case .shorts(let pair):
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(pair) { short in
                            ShortPoster(item: short) { onPlay(short) }
                                .videoContextMenu(short)
                        }
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .onAppear { pair.forEach(appeared) }
                case .shelf(let shorts):
                    ShortsShelf(items: shorts, onAppearItem: onAppearItem, onPlay: onPlay)
                }
            }
        }
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
                        ShortPoster(item: short) { onPlay(short) }
                            .videoContextMenu(short)
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
