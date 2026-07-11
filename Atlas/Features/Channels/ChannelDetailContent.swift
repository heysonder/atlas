import PipedKit
import SwiftUI

struct ChannelDetailContent: View {
    let channel: Channel
    let channelID: String
    let shownItems: [StreamItem]
    let hasFilteredItems: Bool
    let watchedIDs: Set<String>
    let isSubscribed: Bool
    let reduceMotion: Bool
    let hasNextPage: Bool
    let isLoadingNextPage: Bool
    let paginationError: String?
    let loadMoreToken: String
    let onToggleSubscription: () -> Void
    let onAppearItem: (StreamItem) -> Void
    let onPlay: (StreamItem) -> Void
    let onLoadNextPage: () async -> Void
    let onRetryNextPage: () async -> Void
    let onRefresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ChannelHeaderView(
                    channel: channel,
                    isSubscribed: isSubscribed,
                    reduceMotion: reduceMotion,
                    onToggleSubscription: onToggleSubscription)

                Divider()
                    .padding(.horizontal)

                if shownItems.isEmpty {
                    emptyState
                } else {
                    GroupedVideoList(
                        items: shownItems,
                        avatarFallback: channel.avatarURL,
                        channelIDFallback: channelID,
                        shortsLayout: .carousel,
                        watchedIDs: watchedIDs,
                        onAppearItem: onAppearItem,
                        onPlay: onPlay
                    )
                    .onScreenVideos(shownItems)
                    .padding(.horizontal)
                    paginationFooter
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await onRefresh() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let paginationError {
            paginationFailure(paginationError)
                .padding(.top, 40)
        } else if hasNextPage || isLoadingNextPage {
            ProgressView("Loading videos…")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .task(id: loadMoreToken) { await onLoadNextPage() }
        } else if hasFilteredItems {
            ContentUnavailableView(
                "Videos hidden",
                systemImage: "eye.slash",
                description: Text(
                    "This channel’s available Shorts are hidden by your Content setting.")
            )
            .padding(.top, 40)
        } else {
            ContentUnavailableView(
                "No videos to show",
                systemImage: "play.slash",
                description: Text(
                    "This instance returned no uploads for this channel. "
                        + "Try another instance in Settings.")
            )
            .padding(.top, 40)
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if let paginationError {
            paginationFailure(paginationError)
                .padding(.vertical, 12)
        } else if isLoadingNextPage {
            ProgressView("Loading more videos…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else if hasNextPage {
            Color.clear
                .frame(height: 1)
                .id(loadMoreToken)
                .task(id: loadMoreToken) { await onLoadNextPage() }
        }
    }

    private func paginationFailure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Label("Couldn’t load more videos", systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await onRetryNextPage() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
}
