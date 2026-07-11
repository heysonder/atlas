import PipedKit
import SwiftUI

struct FeedContentView: View {
    let videos: [StreamItem]
    let shortsLayout: ShortsLayout
    let isLoadingMore: Bool
    let canLoadMore: Bool
    let paginationError: String?
    let loadMoreToken: String
    let onAppearItem: (StreamItem) -> Void
    let onPlay: (StreamItem) -> Void
    let onRefresh: () async -> Void
    let onLoadMore: () async -> Void
    let onRetryLoadMore: () async -> Void

    var body: some View {
        ScrollView {
            if videos.isEmpty {
                ContentUnavailableView(
                    "You're all caught up",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing new to show right now — pull to refresh.")
                )
                .padding(.top, 60)
            } else {
                GroupedVideoList(
                    items: videos,
                    shortsLayout: shortsLayout,
                    onAppearItem: onAppearItem,
                    onPlay: onPlay
                )
                .onScreenVideos(videos)
                .padding(.horizontal)
                .padding(.top, 8)
                paginationFooter
            }
        }
        .refreshable { await onRefresh() }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if isLoadingMore {
            ProgressView()
                .accessibilityLabel("Loading more videos")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else if let paginationError {
            VStack(spacing: 8) {
                Label("Couldn’t load more videos", systemImage: "wifi.exclamationmark")
                    .font(.callout.weight(.semibold))
                Text(paginationError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await onRetryLoadMore() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if canLoadMore {
            Color.clear
                .frame(height: 1)
                .id(loadMoreToken)
                .onAppear { Task { await onLoadMore() } }
        }
    }
}
