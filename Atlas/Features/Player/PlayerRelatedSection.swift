import PipedKit
import SwiftData
import SwiftUI

/// "Related" videos beneath the embedded player's info column, built from the
/// `relatedStreams` the /streams response already carries — no extra fetch.
/// Watched videos stay listed but badged, matching the channel page.
struct PlayerRelatedSection: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]
    @State private var watchedMemo = WatchedIDsMemo()

    let related: [StreamItem]
    let currentVideoID: String
    let onPlay: (StreamItem) -> Void

    private var videos: [StreamItem] {
        StreamItemIdentity.firstOccurrences(
            in: app.filteringShorts(
                related.filter { $0.isVideo && $0.videoID != currentVideoID }))
    }

    var body: some View {
        let videos = videos
        if !videos.isEmpty {
            let watchedIDs = watchedMemo.ids(for: history)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("Related")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(videos.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(videos) { item in
                        VideoRow(
                            item: item,
                            watched: item.videoID.map(watchedIDs.contains) ?? false,
                            onPlay: { onPlay(item) })
                    }
                }
            }
        }
    }
}
