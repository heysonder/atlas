import PipedKit
import SwiftUI

struct ChannelDetailContent: View {
    let channel: Channel
    let channelID: String
    let liveStream: StreamItem?
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

    private var visibleItems: [StreamItem] {
        (liveStream.map { [$0] } ?? []) + shownItems
    }

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

                if let liveStream {
                    VStack(alignment: .leading, spacing: 10) {
                        liveNowHeader
                        VideoRow(
                            item: liveStream,
                            avatarFallback: channel.avatarURL,
                            channelIDFallback: channelID,
                            watched: liveStream.videoID.map(watchedIDs.contains) ?? false,
                            liveStatusOverride: true
                        ) { onPlay(liveStream) }
                        .videoContextMenu(liveStream)
                        .onAppear { onAppearItem(liveStream) }
                    }
                    .padding(.horizontal)

                    if !shownItems.isEmpty {
                        Divider()
                            .padding(.horizontal)
                    }
                }

                if shownItems.isEmpty {
                    if liveStream == nil {
                        emptyState
                    } else {
                        paginationFooter
                    }
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
                    .padding(.horizontal)
                    paginationFooter
                }
            }
            .onScreenVideos(visibleItems)
            .padding(.bottom, 24)
        }
        .refreshable { await onRefresh() }
    }

    /// Names the pinned row so it reads as "this channel is live now" rather
    /// than an unexplained video floating above the uploads. Mirrors the
    /// Shorts shelf header style.
    private var liveNowHeader: some View {
        Label {
            Text("Live now")
        } icon: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color(.systemRed))
        }
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
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
