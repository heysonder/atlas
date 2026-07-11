import PipedKit
import SwiftUI

/// A `LazyVStack` of videos that renders Shorts as paired 9:16 posters (or one
/// horizontal shelf, in carousel layout) and warms upcoming thumbnails as rows
/// appear. Shared by the feed, search, recs, channel.
struct GroupedVideoList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

    init(
        items: [StreamItem],
        avatarFallback: String? = nil,
        channelIDFallback: String? = nil,
        spacing: CGFloat = 20,
        shortsLayout: ShortsLayout = .inline,
        watchedIDs: Set<String> = [],
        onAppearItem: ((StreamItem) -> Void)? = nil,
        onPlay: @escaping (StreamItem) -> Void
    ) {
        self.items = StreamItemIdentity.firstOccurrences(in: items)
        self.avatarFallback = avatarFallback
        self.channelIDFallback = channelIDFallback
        self.spacing = spacing
        self.shortsLayout = shortsLayout
        self.watchedIDs = watchedIDs
        self.onAppearItem = onAppearItem
        self.onPlay = onPlay
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            gridLayout
        } else {
            stackLayout
        }
    }

    /// Single-column feed (iPhone): full-width videos with Shorts paired 2-up or
    /// pulled into a shelf, per `shortsLayout`.
    private var stackLayout: some View {
        let firstIndexByID = firstIndexByID()
        return LazyVStack(spacing: spacing) {
            ForEach(groupedVideoRows(items, layout: shortsLayout)) { row in
                switch row {
                case .video(let item):
                    videoCell(item, index: firstIndexByID[item.id])
                case .shorts(let pair):
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(pair) { short in
                            ShortPoster(item: short, watched: isWatched(short)) { onPlay(short) }
                                .videoContextMenu(short)
                        }
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .onAppear {
                        pair.forEach { appeared($0, index: firstIndexByID[$0.id]) }
                    }
                case .shelf(let shorts):
                    ShortsShelf(
                        items: shorts, watchedIDs: watchedIDs,
                        onAppearItem: onAppearItem, onPlay: onPlay)
                }
            }
        }
    }

    /// Multi-column feed (iPad and larger): regular videos flow into an adaptive
    /// grid that fits as many ~300pt columns as the width allows; Shorts collapse
    /// into a single horizontal shelf near the top (their tall 9:16 posters don't
    /// tile cleanly beside wide 16:9 cards).
    private var gridLayout: some View {
        let track = [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]
        let shorts = items.filter { $0.isShort == true }
        let videos = items.filter { $0.isShort != true }
        let firstIndexByID = firstIndexByID()
        // Lead with a few videos, then the shelf, then the rest — so the feed opens
        // on real videos rather than a wall of Shorts. With an adaptive column count
        // we no longer know the row size, so we lead with a fixed handful.
        let leadCount = shorts.isEmpty ? videos.count : min(4, videos.count)
        let lead = videos.prefix(leadCount)
        let rest = videos.dropFirst(leadCount)

        return LazyVStack(spacing: spacing) {
            if !lead.isEmpty {
                LazyVGrid(columns: track, spacing: spacing) {
                    ForEach(lead) {
                        videoCell(
                            $0,
                            index: firstIndexByID[$0.id],
                            reservesTitleSpace: true)
                    }
                }
            }
            if !shorts.isEmpty {
                ShortsShelf(
                    items: shorts, watchedIDs: watchedIDs,
                    onAppearItem: onAppearItem, onPlay: onPlay)
            }
            if !rest.isEmpty {
                LazyVGrid(columns: track, spacing: spacing) {
                    ForEach(rest) {
                        videoCell(
                            $0,
                            index: firstIndexByID[$0.id],
                            reservesTitleSpace: true)
                    }
                }
            }
        }
    }

    /// One video card, shared by the stack and grid layouts. The grid reserves a
    /// two-line title height so every card matches, keeping the columns aligned.
    private func videoCell(
        _ item: StreamItem,
        index: Int?,
        reservesTitleSpace: Bool = false
    ) -> some View {
        VideoRow(
            item: item,
            avatarFallback: avatarFallback,
            channelIDFallback: channelIDFallback,
            watched: isWatched(item),
            reservesTitleSpace: reservesTitleSpace
        ) { onPlay(item) }
        .videoContextMenu(item)
        .onAppear { appeared(item, index: index) }
    }

    private func isWatched(_ item: StreamItem) -> Bool {
        guard let id = item.videoID else { return false }
        return watchedIDs.contains(id)
    }

    /// Notify + warm the thumbnails of the next handful of items so they're ready
    /// before the user scrolls to them.
    private func appeared(_ item: StreamItem, index: Int?) {
        onAppearItem?(item)
        guard let index else { return }
        let start = index + 1
        let end = min(start + 10, items.count)
        guard start < end else { return }
        let urls = items[start..<end].map { ThumbnailURL.upgraded($0.thumbnail) }
        guard let client = try? app.httpClient else { return }
        let generation = app.instanceGeneration
        Task {
            await ThumbnailPrefetcher.shared.prefetch(
                urls, client: client, generation: generation)
        }
    }

    /// Preserves the previous first-match behavior when malformed input contains
    /// duplicate ids, while avoiding one linear lookup for every appearing row.
    private func firstIndexByID() -> [String: Int] {
        Dictionary(
            items.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
    }
}

/// A horizontal, swipeable row of Shorts posters with a "Shorts" header. Lazily
/// loads posters so a long shelf doesn't fetch every thumbnail up front.
private struct ShortsShelf: View {
    @Environment(AppModel.self) private var app
    let items: [StreamItem]
    var watchedIDs: Set<String> = []
    var onAppearItem: ((StreamItem) -> Void)? = nil
    let onPlay: (StreamItem) -> Void

    private let cardWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shorts", systemImage: "play.square.stack.fill")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { short in
                        ShortPoster(
                            item: short,
                            watched: short.videoID.map(watchedIDs.contains) ?? false
                        ) { onPlay(short) }
                        .videoContextMenu(short)
                        .frame(width: cardWidth)
                        .onAppear { onAppearItem?(short) }
                    }
                }
            }
            .scrollClipDisabled()
        }
        .onAppear {
            let urls = items.prefix(8).map { ThumbnailURL.upgraded($0.thumbnail) }
            guard let client = try? app.httpClient else { return }
            let generation = app.instanceGeneration
            Task {
                await ThumbnailPrefetcher.shared.prefetch(
                    urls, client: client, generation: generation)
            }
        }
    }
}
